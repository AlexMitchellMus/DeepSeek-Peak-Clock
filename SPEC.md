# DeepSeek Tracker — Build Spec v1

Track DeepSeek API pricing status (peak vs off-peak) with a **large countdown to the next
price change**, the switch time in the user's zone, a progress bar for the current window,
and a compact **metrics row** (API status / uptime / latency / optional balance).
One skin, light and dark.

Reference product: <https://deepakness.com/deepseek/> (a peak/off-peak price clock).
We re-implement its timing model faithfully (the 2026 rules) and add a live metrics row.

---

## 1. Surfaces / deliverables

| Surface | Path | Notes |
| --- | --- | --- |
| **Native macOS widget + app** | `native/`, `dist/` | SwiftUI + WidgetKit, small/medium/large, one skin in light/dark, packaged by `tools/package.sh`. Primary deliverable. |
| Metrics collector | `collector/` | Node ≥20, zero deps, writes `metrics/metrics.json`, optional localhost server. |
| Swift core | `native/DeepSeekCore/` | Foundation-only peak clock + pricing + metrics models, unit-tested against `spec/vectors.json`. |

Non-goals: DeepSeek account login, billing writes, iOS.

---

## 2. Timing model (canonical — do not "improve")

All calculations are in **UTC**. The 2026 DeepSeek price clock splits weekday time into two
peak windows and treats Chinese weekends/public holidays as off-peak all day.

```
SWITCH_MINUTES = [60, 240, 360, 600]        // UTC minutes-of-day
peak  ⇔ minuteOfDay ∈ [60,240) ∪ [360,600)  // 01:00–04:00 and 06:00–10:00 UTC
off   ⇔ everything else
```

* `WEEKEND_RULE_START = Date.UTC(2026, 7, 22, 16)` → 2026-08-22T16:00Z (00:00 Beijing,
  Sunday 23 Aug 2026). Only instants **at/after** this use the weekend rule.
* Beijing weekend = Beijing wall-clock Saturday or Sunday (`t + 8h`, `getUTCDay() ∈ {0,6}`).
* `CN_HOLIDAYS` (Beijing dates, inclusive):
  * 2026-09-25 → 2026-09-27 (Mid-Autumn)
  * 2026-10-01 → 2026-10-07 (National Day)
  * Add future years when announced; make-up workdays are intentionally ignored.
* `offPeakAllDay(t) = t ≥ WEEKEND_RULE_START ∧ (Beijing weekend(t) ∨ Beijing holiday(t))`
* `kind(t) = offPeakAllDay(t) ? "off" : (minuteOfDay(t) ∈ peakRanges ? "peak" : "off")`
* A switch instant `t` (minuteOfDay ∈ SWITCH_MINUTES) is a **real** price change only when
  `!offPeakAllDay(t)`; otherwise it is skipped. This merges Friday 16:00Z → Monday 01:00Z
  into one long off-peak run.

Derived values:
* `nextSwitch(t)` — first real switch instant strictly after `t`, scanning day by day.
* `windowStart(t)` — most recent real switch instant ≤ `t` (scan back 21 days; holiday runs
  can exceed 10 days).
* `windows(t, n)` — n windows `{start, end, kind, current}`, first one is the current window.
* 24 h display bar: segments in **display** time (local by default, UTC on toggle). Boundaries
  = 0/1440 + every switch minute + 960 (Beijing midnight) shifted by the display offset and
  wrapped into [0,1440). Adjacent equal-kind segments merge. Sample the midpoint of each
  segment to decide its kind.
* Labels: if a window start/end fall on different display days, show weekday/date on both
  ends ("Fri 15:30 – Mon 06:30"). "Far" (≥6 days) labels include the date and time zone.
* Countdown formatting `H:MM:SS` (hours do not wrap into days: a 3-day weekend shows `57:12:40`).
* Window meta: current row reads `now · 3h 12m left`; other rows read `4h`, `3d 8h`.

### Test vectors
`spec/vectors.json` is generated from the reference implementation
(`spec/reference-clock.mjs`) and is the source of truth for all three implementations.
Any implementation must reproduce every vector. Regenerate with `node spec/vectors.mjs`.

---

## 3. Pricing table (USD per 1M tokens)

| Model | Bucket | Off-peak | Peak |
| --- | --- | --- | --- |
| DeepSeek V4.1 Flash | input | $0.15 | $0.30 |
| | cached input | $0.003 | $0.006 |
| | output | $0.60 | $1.20 |
| DeepSeek V4 Pro | input | $0.66 | $1.32 |
| | cached input | $0.022 | $0.044 |
| | output | $1.98 | $3.96 |

Rules: peak = off-peak × 2. Off-peak is currently "half price". Web search / fetch:
$0.75 per 1K requests (shown as a footnote, not a rate card). Legacy names V4 Flash and
Vision Exp bill at Flash rates. Both models: 1M context, up to 384K output.

---

## 4. Metrics contract — `metrics/metrics.json` (schema v1)

The collector is the only writer. Consumers (app, widget) must tolerate a
missing file, a stale file, and a partial file, and must render a `loading` / `stale` /
`unavailable` state instead of breaking.

```jsonc
{
  "schema": 1,
  "generated_at": "2026-10-30T09:12:00Z",   // ISO-8601 UTC
  "source": "status.deepseek.com",
  "status": {
    "overall": "operational",               // operational|degraded|partial_outage|full_outage|maintenance|unknown
    "label": "All systems operational",     // short human string, fallback if empty
    "components": [                          // at most 6, ordered by importance
      { "id": "01KY...", "name": "DeepSeek V4.1 Flash API", "status": "operational",
        "uptime": 99.85 }                    // uptime = 90-day %, nullable
    ],
    "active_incidents": 0
  },
  "latency": {                               // measured locally by the collector
    "ok": true, "ms": 214, "p50_ms": 198, "samples": 5,
    "endpoint": "api.deepseek.com", "checked_at": "2026-10-30T09:12:00Z"
  },
  "balance": {                               // optional; only with DEEPSEEK_API_KEY
    "available": true, "currency": "USD", "total": 12.34,
    "top_up": 10.0, "granted": 2.34, "key_hint": "sk-…abcd"
  },
  "error": null                              // string when a source failed
}
```

Age policy for UI: `age < 2 min` → live; `2–15 min` → "updated 4m ago" (dimmed);
`> 15 min` or missing → `stale`/`unavailable` with a retry affordance.

Data sources. The **native widget fetches directly** (no setup): it parses
`https://status.deepseek.com/` for component health and active incidents and times three
requests to `https://api.deepseek.com/models` (401 counts as reachable). The **optional
collector** is preferred when it answers on `127.0.0.1:8787` because it adds 90-day
section uptimes and, with `DEEPSEEK_API_KEY`, the account balance. Both write the same
schema, so the UI does not care which source answered.

---

## 5. Visual design — one simple card

The countdown is the hero; everything else is deliberately quiet. One skin, system
appearance for light/dark. No theme picker.

| Token | Light | Dark |
| --- | --- | --- |
| card | `rgba(255,255,255,.80)` over `.ultraThinMaterial`, 26 pt radius | `rgba(28,28,30,.66)` over `.ultraThinMaterial` |
| text / secondary / tertiary | `#1C1C1E` / `#6E6E73` / `#8E8E93` | `#F5F5F7` / `#A1A1A6` / `#848489` |
| hairline | `rgba(0,0,0,.09)` | `rgba(255,255,255,.11)` |
| off-peak | `#1DB954` (dark `#30D158`) | pill fill 15–20 % of it |
| peak | `#FF3B30` (dark `#FF453A`) | pill fill 13–22 % of it |
| card wash | 10 % status colour, top-leading → clear | same |

Layout, top to bottom:

1. **Pill** — status dot + "Peak pricing" / "Off-peak · half price"; zone label on the right
   (hidden on small).
2. **Eyebrow** — `UNTIL OFF-PEAK PRICING` while peak, `UNTIL PEAK PRICING` while off-peak
   (small family: `UNTIL OFF-PEAK` / `UNTIL PEAK`).
3. **Countdown** — semibold, tabular numerals, negative tracking, auto-shrunk to fit.
4. **Switch line** — `Off-peak starts 8:30 pm` (weekday when it isn't today).
5. **Schedule bar** — the display day's peak/off-peak segments with a "now" notch and
   hour labels (12 am / 6 am / 12 pm / 6 pm; labels hidden on small).
6. **Metrics row** — dot + status + uptime + latency (small: status + latency); large adds
   `6 services · 0 incidents`. Four states: loading / live / stale / unavailable.

Type scale (pt): small countdown 46, medium 64, large 112; eyebrow 9.5/10.5/13; pill
10.5/11/13; switch line 11/12/15; metrics 9.5/10.5/12.5; card padding 13/17/22.

## 6. Widget behaviour

* 1 Hz tick; the countdown uses `Text(timerInterval:)` in the widget so the system animates
  it without timeline refreshes.
* Timeline refreshes at the next price switch and at most every 15 minutes.
* Metrics: local collector first, direct DeepSeek probe as the fallback; unreachable →
  `Metrics offline`, never a broken card. Prices are always local.
* Reduced motion honoured; the card carries accessibility labels for the state, the
  countdown ("UNTIL OFF-PEAK PRICING 1:00:00") and the timeline progress.
* Families: small 158×158 (pill, countdown, switch line, metrics), medium 338×158 (adds
  uptime), large 338×354 (bigger type, service/incident line). `contentMarginsDisabled()`
  so the card owns its own padding.

## 7. Acceptance criteria

1. `node spec/vectors.mjs --check` and `swift test` agree on every vector (kind at
   instant, next switch, window start, display segments), including the two cases that
   cross local midnight.
2. `xcodebuild -scheme DeepSeekTracker build` succeeds; the widget extension is embedded
   in the app bundle and carries its sandbox + network entitlements.
3. `tools/package.sh` produces an installer in `dist/` that installs the app and leaves
   exactly one widget registration (the `/Applications` copy).
4. Screenshots exist for light/dark and all three families in
   `artifacts/screens/widget-*.png`, including a weekend day.
5. Metrics render in all four states (loading / live / stale / unavailable); the card
   works with DeepSeek unreachable. Prices never depend on the network.
6. `tools/verify.sh` passes on a clean checkout.
7. No runtime dependencies: no npm packages, no Swift packages, no CDNs, no bundled fonts.

---

## 8. Layout

| Path | What |
| --- | --- |
| `native/` | app + WidgetKit extension; `DeepSeekCore/` is the tested Foundation-only core |
| `collector/` | optional metrics collector (Node) |
| `spec/` | rules, reference implementation, `vectors.json` |
| `tools/` | package, render, project generation, verify |
| `docs/` | build notes, metrics schema, Swift core API |
| `dist/` | built installer (generated, git-ignored) |
