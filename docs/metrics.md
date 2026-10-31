# Metrics collector & `metrics/metrics.json` (schema v1)

The collector is the **only** writer of `metrics/metrics.json`. It is a single
zero-dependency Node (>= 20) script:

```
collector/status-collector.mjs
```

It turns three independent sources — the DeepSeek status page, a local latency
probe, and (optionally) your account balance — into the metrics object defined by
[SPEC.md §4](../SPEC.md). It also has a tiny localhost HTTP server so the
The native app and widget read the file over `http://127.0.0.1:8787/metrics.json`, without `file://` restrictions.

Design contract: consumers must tolerate a **missing** file, a **stale** file,
and a **partial** file. The collector writes atomically, never writes a document
that fails its own schema validation, and degrades one source at a time instead
of failing the whole cycle.

---

## Quick start

```bash
# one collection cycle (default), writes metrics/metrics.json
node collector/status-collector.mjs --once

# continuous collection every 60s
node collector/status-collector.mjs --interval 60

# serve the JSON over HTTP (reads the file fresh on every request)
node collector/status-collector.mjs --serve 8787

# collect every 60s AND serve on 8787
node collector/status-collector.mjs --serve 8787 --interval 60

# collect once, then keep serving
node collector/status-collector.mjs --serve 8787 --once

# custom output path (parent directories are created)
node collector/status-collector.mjs --once --out metrics/metrics.json

# help
node collector/status-collector.mjs --help
```

Run the offline test suite (no network, no writes outside `.tmp/`):

```bash
node --test collector/
```

---

## CLI reference

| Flag | Default | Meaning |
| --- | --- | --- |
| `--once` | (implicit) | Collect one cycle, write the file, exit. |
| `--interval <seconds>` | — | Collect forever, sleeping N seconds between cycles. Must be > 0. |
| `--out <path>` | `metrics/metrics.json` | Output file. Directories are created. |
| `--serve [port]` | `8787` | Serve over HTTP on `127.0.0.1:<port>`. With `--interval`, also collects. With explicit `--once`, collects once first. Alone, serves whatever is on disk. |
| `--help`, `-h` | — | Print usage to stdout. |

`--once` and `--interval` are mutually exclusive.

**Logging.** One structured JSON line per cycle on **stderr**:

```json
{"event":"cycle","ms":1960,"overall":"operational","latency_ms":426,"components":6,"active_incidents":0,"warnings":0,"error":null}
```

No other output on success (so cron/launchd logs stay quiet). Serve startup and
shutdown are logged as `{"event":"serve",…}` / `{"event":"shutdown",…}`; fatal
configuration problems as `{"event":"fatal",…}`.

**Exit codes.** `0` for a completed cycle even if every network source failed
(that is a normal degraded state). Non-zero (currently `1`) only for fatal
configuration errors: bad/unknown flags, unreadable/unwritable output location,
port already in use, or Node < 20.

---

## The JSON contract (SPEC §4, schema v1)

```jsonc
{
  "schema": 1,
  "generated_at": "2026-10-30T09:12:00Z",   // ISO-8601 UTC, second precision
  "source": "status.deepseek.com",
  "status": { … },
  "latency": { … },
  "balance": { … },                          // optional
  "error": null,                             // string when any source failed
  "warnings": []                             // additive, see below
}
```

### Field-by-field

| Field | Type | Notes |
| --- | --- | --- |
| `schema` | `1` | Contract version. `warnings` is additive on top of v1. |
| `generated_at` | ISO-8601 UTC string | When *this* cycle wrote the file. Second precision (`…Z`), matching the SPEC sample. `null` is allowed only in the synthetic `unavailable` fixture shape. |
| `source` | string | Always `"status.deepseek.com"` for schema v1. |
| `status` | object \| `null` | See below. `null` only in the synthetic "nothing collected" shape. |
| `status.overall` | enum | `operational` \| `degraded` \| `partial_outage` \| `full_outage` \| `maintenance` \| `unknown`. |
| `status.label` | string | Short human fallback: e.g. `"All systems operational"`. Never empty. |
| `status.components` | array (≤ 6) | Ordered by importance; see *Component selection*. |
| `status.components[].id` | string | Flashcat component id (stable). |
| `status.components[].name` | string | Short English-ish display name. |
| `status.components[].status` | enum | `operational` \| `degraded` \| `partial_outage` \| `full_outage` \| `maintenance`. |
| `status.components[].uptime` | number \| `null` | 90-day uptime percentage (0–100, 2 decimals) from `component_uptimes`/`section_uptimes`, or `null` when unknown. |
| `status.active_incidents` | integer ≥ 0 | Distinct currently-open incidents/maintenance affecting the page. |
| `latency.ok` | boolean | At least one probe received a non-5xx HTTP response. |
| `latency.ms` | number \| `null` | Wall-clock ms of the **latest** successful probe; `null` when `ok:false`. |
| `latency.p50_ms` | number \| `null` | Median of successful probe samples; `null` when `ok:false`. |
| `latency.samples` | integer ≥ 0 | Number of **successful** probes (max 5). Failed probes are not samples. |
| `latency.endpoint` | string | `"api.deepseek.com"` (the probed path is `/models`; the SPEC sample is host-only). |
| `latency.checked_at` | ISO-8601 UTC string | When the latency source finished. |
| `balance.available` | boolean | `true` only when the API key is valid and the balance payload parsed. |
| `balance.currency` | string | 3-letter code, present when available. |
| `balance.total` / `top_up` / `granted` | numbers | Present when available. |
| `balance.key_hint` | string | `"sk-…abcd"` — last 4 characters only. **Never the key.** |
| `balance.reason` | string | Present when `available:false`, see *Balance reasons*. |
| `error` | `null` \| string | `"; "`-joined source errors when any source failed, even if last-good values were served. |
| `warnings` | array of strings | Additive; empty on a fully successful cycle. |

### `warnings` (additive)

When a source fails but a previous value is available, that value is kept and a
warning is added:

```
stale_source:status — source failed this cycle (timeout after 10000ms); serving last-good snapshot from 2026-10-30T08:45:00Z
stale_source:latency — source failed this cycle (ENETDOWN); serving last-good snapshot from …
```

Prefix `stale_source:<status|latency|balance>` is machine-scannable. The
top-level `error` field is still set (the source did fail); UIs that only know
the four SPEC fields can ignore `warnings` entirely.

### Age policy helpers

`ageState(generatedAt, now)` implements SPEC §4 so every surface agrees:

| Age | `state` | `label` |
| --- | --- | --- |
| `< 2 min` | `live` | `null` |
| `2–15 min` (inclusive of 15 min) | `aged` | `"updated 4m ago"` (dimmed) |
| `> 15 min` | `stale` | `"updated 22m ago"` (retry affordance) |
| missing/invalid | `unavailable` | `"no data"` |

`formatAge()` renders `just now`, `4m`, `1h 30m`, `1d 2h`. Future timestamps
(clock skew) are treated as `live`, never stale.

---

## Data sources (exact URLs)

| Source | URL | Auth | Timeout |
| --- | --- | --- | --- |
| Status page (HTML → flight payload) | `https://status.deepseek.com/` | none | 10 s hard |
| Latency probe | `https://api.deepseek.com/models` | none (401 is expected & counts as reachable) | 3 s per probe, 10 s budget |
| Balance (optional) | `https://api.deepseek.com/user/balance` | `Authorization: Bearer $DEEPSEEK_API_KEY` | 10 s hard |

All three run concurrently per cycle; each is wrapped in its own timeout and
catches its own errors. A cycle is typically ~2 s (status page DOM ~230 KB,
latency probes ~0.3–0.8 s each).

---

## Status page: how the data was discovered

### 1. There is no public JSON status API

`status.deepseek.com` is a Flashcat status page rendered by Next.js (App
Router). Every plausible JSON endpoint returns a Next.js `404 RouteNotFound`:

| Probed path | Result |
| --- | --- |
| `/api/health` | **200** `{"status":"ok"}` — but this is *page service* health, not status data |
| `/api/status`, `/api/v1/status`, `/api/v2/status` | 404 |
| `/api/components`, `/api/v1/components` | 404 |
| `/api/incidents` | 404 |
| `/api/status-page`, `/api/statuspage` | 404 |
| `/api/page/6410630422455`, `/api/pages/6410630422455` | 404 |
| `/api/status_page/6410630422455`, `/api/v1/status_page/6410630422455` | 404 |
| `/api/public/status`, `/api/status/pages/6410630422455`, `/api/v1/pages/6410630422455/status` | 404 |
| `/api/feed`, `/api/rss` | 404 |
| `/rss`, `/atom`, `/feed` | 307 → `/` (no feed exists) |
| `/feed.xml`, `/rss.xml`, `/robots.txt`, `/sitemap.xml` | 200 `text/html` SPA fallback, not data |

The page references 22 Next.js JS chunks under
`https://static.flashcat.cloud/status-page/_next/static/chunks/…`; none mentions
an `/api/` path. The page id is `6410630422455`. Conclusion: parse the
server-rendered HTML.

### 2. The flight payload

The SSR document embeds the React Server Components data as
`self.__next_f.push([1,"…"])` chunks. The collector:

1. finds each `self.__next_f.push(` call,
2. scans the JSON array argument with a string/escape-aware bracket scanner and
   `JSON.parse`s it,
3. concatenates the string in slot `[1]` of every chunk (a payload may be split
   over several pushes; the live page currently uses one).

Inside the concatenated payload, keyed lookups find these blocks (their flight
row ids, e.g. `3b:`/`3a:`/`3e:`, are build-specific — **never** rely on them):

| Key | Contents used |
| --- | --- |
| `"initialPageConfig":{…}` | `components[]` (`component_id`, `section_id?`, `name`, `order_id`), `sections[]` (`section_id`, `order_id`). `initialData`→`page` is the fallback location if this key disappears. |
| `"initialData":{…}` (1st, with `page`) | `active_changes[]` — the page's own list of currently-active incidents (empty when all-clear). |
| `"initialData":{…}` (2nd) | `section_uptimes[]`, `component_uptimes[]`, `section_impacts[]`, `component_impacts[]`, `linked_changes[]`. |
| `"initialCalendarData":{…}` | `changes[]` — incidents/maintenance with `type`, `status`, `start_at_seconds`, `close_at_seconds`, `updates[]`. |
| `"initialDataUpdatedAt":<ms>` | When Flashcat rendered the data (sanity-checked). |

An impact row looks like:

```json
{ "component_id": "01KY4MVS8BM3F9JSYWACGQVG7A", "section_id": "",
  "change_id": 7170710513287, "start_at_seconds": 1793084859,
  "end_at_seconds": 1793085714, "status": "degraded" }
```

A component row looks like:

```json
{ "component_id": "01KY4MVS8BM3F9JSYWACGQVG7A",
  "name": "DeepSeek V4 Pro API服务(API Service)",
  "description": "…", "available_since_seconds": 1706745600, "order_id": 1 }
```

### 3. Derivation rules

**Component status.** Active impacts are those with
`start_at_seconds <= now < end_at_seconds` (an open-ended impact has a null
end). A component takes the worst active `component_impacts` status; components
with a `section_id` also inherit the worst active `section_impacts` status for
their section. No active impact → `operational`.

**Overall.** Severity is `full_outage (3) > partial_outage (2) > degraded (1) >
operational (0)`, computed across **all** components *before* the six-component
cap, so an outage on a low-priority component still surfaces. `maintenance` is
used when a scheduled-maintenance window is active and no worse incident state
exists (`maintenance` changes in the calendar/active list, or impacts with
status `maintenance`). `unknown` only when the page cannot be parsed with
confidence — never fabricated.

**Active incidents.** Distinct `change_id`s that are either an open incident
(`start <= now < close`, or open-ended) in the calendar, in the page's
`active_changes` list, or the `change_id` of an active impact. Maintenance
changes are counted in `active_incidents` only when they are, in fact, open.

**Component names.** The page labels mix Chinese and English, e.g.
`"DeepSeek V4.1 Flash API服务(API Service)"`. The collector strips the trailing
Chinese parenthetical and the Chinese `服务` suffix, preferring the Latin part of
the main label and falling back to the English parenthetical for
Chinese-first labels (`搜索API服务(Search API Service)` → `Search API Service`,
`对话服务(Chatservice)` → `Chat Service`).

**Ordering & cap.** At most 6 components per SPEC. Standalone API components
come first (by `order_id`), then components grouped under a section (by section
`order_id`, then component `order_id`). With the live page that is:
`V4 Pro API`, `V4.1 Flash API`, `Search API Service`, `Fetch API Service`,
`Chat Service`, `File Upload Service`. The 7th page component (`Search Service`
inside the Chat section) is dropped by the cap.

**Sanity checks.** Empty component list, missing page config, missing
uptime/impact data, invalid status enums, or embedded data older than 7 days /
more than 10 minutes in the future ⇒ the status source throws, and the collector
emits `overall:"unknown"` + `error` (or the last-good snapshot, if any).

### 4. Observed live values (2026-10-30)

Captured with the collector and the saved fixture `collector/fixtures/status-page.html.gz`:

| Component | Status | 90-day uptime |
| --- | --- | --- |
| DeepSeek V4 Pro API | operational | 99.74% |
| DeepSeek V4.1 Flash API | operational | 99.47% |
| Search API Service | operational | 100.00% |
| Fetch API Service | operational | 100.00% |
| Chat Service | operational | 99.62% |
| File Upload Service | operational | 100.00% |

Overall `operational`, `active_incidents: 0`, page data freshness ~2 min.
The Chat section's group uptime is 99.85% (section-level); the collector reports
each child component's own uptime.

---

## Latency source

Five **sequential** `GET https://api.deepseek.com/models` probes with no API key:

* 3 s `AbortController` timeout per probe; 10 s budget for the whole source.
* `401` (or any non-5xx response) proves reachability — `ok:true`.
* 5xx, timeouts, and network errors count as failed probes (not samples). The
  source stops early when its budget is exhausted.
* Wall time includes response body drain (which also keeps the keep-alive socket
  warm for the next probe). `ms` = latest successful sample, `p50_ms` = median.
* Because it measures the real network path from the collector host, numbers
  vary with location/ISP; typical measurements from this machine were
  `ms 316–477`, `p50_ms 332–396`, `samples 5`.

`latency.ok:false` (with `ms:null`, `p50_ms:null`, `samples:0`) means the API was
unreachable, not that the account is invalid.

---

## Balance source (optional, `DEEPSEEK_API_KEY`)

The balance source is **off by default**. It only runs when the environment
variable `DEEPSEEK_API_KEY` is set:

```bash
export DEEPSEEK_API_KEY="sk-…"          # keep it out of shell history/scripts if possible
node collector/status-collector.mjs --once
```

Request: `GET https://api.deepseek.com/user/balance` with
`Authorization: Bearer <key>`. Response shape handled:

```json
{
  "is_available": true,
  "balance_infos": [
    { "currency": "USD", "total_balance": "12.34",
      "granted_balance": "2.34", "topped_up_balance": "10.00" }
  ]
}
```

Mapping:

* `balance_infos` may contain several currencies; **USD is preferred** (the
  pricing table is USD), otherwise the first entry is used. `total` ←
  `total_balance`, `top_up` ← `topped_up_balance`, `granted` ← `granted_balance`
  (rounded to 2 decimals).
* `key_hint` is `sk-…` + the last 4 characters. The full key is never written to
  `metrics.json` (there is a test asserting this).
* `401/403`, a null/unparseable body ⇒ `{available:false, reason:"unauthorized"}`.
* No env key ⇒ `{available:false, reason:"no_api_key"}` and **no HTTP request is
  made at all** (also asserted by a test).
* Rate limiting / other HTTP errors ⇒ `reason:"http_<code>"`; transport errors ⇒
  `reason:"network_error"`; malformed payload ⇒ `reason:"bad_payload"`;
  `is_available:false` ⇒ `reason:"not_available"`.

### Balance reasons

| `reason` | Meaning |
| --- | --- |
| `no_api_key` | `DEEPSEEK_API_KEY` not set (expected default). |
| `unauthorized` | 401/403 or null payload — key invalid/expired. |
| `not_available` | API says `is_available:false` (e.g. no balance). |
| `http_<code>` | Unexpected HTTP status. |
| `network_error` | DNS/TLS/connection failure (error also added to top-level `error`). |
| `bad_payload` | JSON did not contain usable `balance_infos` numbers. |
| `internal_error` | Defensive fallback if the balance task itself threw. |

**Security note.** The key lives only in the process environment. It is sent
only to `api.deepseek.com/user/balance`, is never logged (logs contain the
masked hint only when available), and never appears in `metrics.json`. The
collector's HTTP server binds to `127.0.0.1` only and serves only the metrics
document, so no secret is exposed over the network.

---

## Local server (`--serve`)

`http://127.0.0.1:8787` by default; binds to loopback only.

| Route | Response |
| --- | --- |
| `GET /metrics.json` (also `/`) | The file read fresh from disk **on every request**. |
| `GET /health` | `{"status":"ok","out":…,"metrics_present":true,"generated_at":…,"uptime_s":…}` — always `200`; use `metrics_present` to detect a cold start. |
| `OPTIONS *` | `204` with CORS headers. |
| anything else | `404` JSON. |

All responses include:

```
Access-Control-Allow-Origin: *
Cache-Control: no-store
Content-Type: application/json; charset=utf-8
```

`Content-Length` is set, `HEAD` is supported, and a missing metrics file yields
`404 {"error":"metrics_not_collected"}` (not a crash). Because writes are atomic,
serving during a collection cycle always returns a complete document. The server
stays up when `--serve` is used without `--interval`; add `--interval` to keep
collecting, or run `--once` on a timer.

Example:

```bash
$ curl -s -D- http://127.0.0.1:8787/metrics.json | head -12
HTTP/1.1 200 OK
Access-Control-Allow-Origin: *
Cache-Control: no-store
Content-Type: application/json; charset=utf-8
...
```

The widget can then poll `http://127.0.0.1:8787/metrics.json` with
cache-busting, exactly as described in SPEC §6.

---

## Output safety

* **Atomic writes.** The JSON is written to `metrics/metrics.json.tmp.<pid>.<ms>`
  in the same directory, then `rename(2)`d over the target. A reader sees the
  previous document or the new one — never a truncated file, even mid-write.
  A verification run polled the file 950 times across two real collections: 0
  parse errors, 0 schema-invalid snapshots.
* **Self-validation.** Every document is run through `validateMetrics()` before
  the rename. If internal assembly ever produced a schema violation, the
  collector writes a safe `unknown` document with the validation error in
  `error` instead of the bad object.
* **Last-good fallback.** State persists only in memory per process; on startup
  the collector seeds it from the existing `--out` file (`loadLastGood`), so
  even `--once` benefits from a previous snapshot. `unknown` status / failed
  latency / unavailable balance is never used as a last-good baseline.
* **Temp files** live only while a write is in flight and are cleaned up on
  failure.

---

## Fixtures (`metrics/fixtures/`)

Hand-written, deterministic, schema-valid snapshots for tests, humans, and
demoing the UI states. All use a fixed timeline around
**2026-10-30T09:12:00Z**; the widget falls back to a direct DeepSeek probe instead.

| File | `generated_at` | Purpose / shape |
| --- | --- | --- |
| `live.json` | `2026-10-30T09:12:00Z` | Happy path. Overall `operational`, 6 components, latency `ms:214/p50:198`, balance available (`sk-…abcd`). Matches real captured values. |
| `stale.json` | `2026-10-30T08:45:00Z` | 27 min old (≥ 20 min required), `error:null`, no warnings — an old but healthy snapshot that renders dimmed/retry. |
| `degraded.json` | `2026-10-30T09:10:00Z` | 1 active incident; exactly one component (`DeepSeek V4.1 Flash API`) is `partial_outage`; overall is therefore **`partial_outage`** (severity derives upward from the component, per the collector rules). |
| `unavailable.json` | `null` | "Nothing was ever collected": `status`/`latency`/`balance` are all `null`, `generated_at:null`, `error:"no metrics collected yet"`. This null-shape is the documented choice (instead of a fake error-only object); consumers treat any null source as unavailable. |

`unavailable.json` is the one allowed `generated_at:null` shape in
`validateMetrics()`; every document the collector writes has a real timestamp.

Tests also use `collector/fixtures/status-page.html.gz` — a gzip copy of the real
status page captured 2026-10-30 (233 KB → 20 KB) so the HTML parser is tested
against the actual page structure, fully offline.

---

## Failure modes

| Situation | Behaviour |
| --- | --- |
| Status page fetch/parse fails, no last good | `status.overall:"unknown"`, empty components, `error` set, exit 0. |
| Status page fetch/parse fails, last good exists | Last-good `status` written, `warnings:["stale_source:status …"]`, `error` set. |
| Status page HTML changed shape | Parse throws on missing page config / uptime data → unknown + error. Never guesses. |
| Latency all probes fail | `latency.ok:false`, `ms:null`, `p50_ms:null`, `samples:0`; last-good latency reused with `stale_source:latency` warning if available. |
| One latency probe fails | Probe dropped; `samples` < 5; `ok:true` with remaining samples. |
| Balance 401 / null body | `{available:false, reason:"unauthorized"}` (no top-level error). |
| Balance network error, last good exists | Last-good balance reused + `stale_source:balance` warning + `error`. |
| Output dir unwritable / invalid flags / port busy | Fatal config error: JSON `{"event":"fatal"}`, exit 1. |
| Reader opens a partially-written file | Impossible via atomic rename; a missing file is a normal `unavailable` state. |
| Node < 20 | Fatal config error, exit 1. |

---

## Age policy for consumers

`metrics.json` has no TTL of its own. Consumers should use `generated_at` with
the SPEC §4 policy (`ageState()` in the collector is the reference):

```
age < 2 min   → live
2–15 min      → show "updated 4m ago", dimmed (state "aged")
> 15 min      → stale, show retry affordance
missing/invalid → unavailable, muted + hint
```

The widget's 4 render states (`loading`, `live`, `stale`, `unavailable`) map:
`loading` while unread, `live`/`aged` → live content, `stale` from the >15 min
bucket or from a `stale_source:` warning, `unavailable` when the file is missing
or every source is null.

---

## Extending sources

The collector is deliberately plain data-flows:

1. Add a new `collectX({ fetchImpl, env, nowMs, … })` async function that returns
   `{ value, errors }` and **never throws** for expected failures.
2. Kick it off in the `Promise.allSettled` group inside `collectOnce()` and merge
   its result into the metrics object. If the field is additive, keep it inside a
   new key and bump nothing (`schema` stays 1) — or bump `schema` if you change
   an existing field's meaning (then update SPEC.md; the metrics owner cannot
   edit SPEC.md).
3. Extend `validateMetrics()` for the new shape and add offline tests (mock fetch,
   no network).
4. Add a last-good branch + `stale_source:<name>` warning so a transient failure
   does not blank the widget.
5. Document the URL, auth, timeout, and mapping here.

For the status page specifically: if Flashcat ever ships a stable JSON endpoint
(e.g. a documented `/api/...`), replace only the `parseStatusPage`/`collectStatus`
pair; `deriveStatus()` already works on the decoded blobs and the fixture-based
tests will show the contract is unchanged.

---

## Deviation / clarification notes vs SPEC §4

These are additive or explicitly-requested clarifications; `schema` remains **1**:

1. **`warnings`** is an extra top-level array of strings (SPEC calls for an
   additive warnings array when stale sources are served).
2. **`balance.reason`** is an extra field on unavailable balance objects (needed
   to distinguish `no_api_key` / `unauthorized` / `network_error`).
3. **`status.components[].status`** may be `maintenance` (the overall enum
   already includes it).
4. **`latency.endpoint`** is host-only (`"api.deepseek.com"`) to match the SPEC
   sample; the probe path is `/models`, documented here.
5. **`latency.samples`** counts successful probes only (max 5). `ok:false` ⇒
   `samples:0`, `ms:null`, `p50_ms:null`.
6. **`latency.ok`** is reachability (any non-5xx response), so `401` is `ok:true`.
7. **Component cap** drops the 7th page component (`Search Service` in the Chat
   section) after ordering; overall severity is still computed over all 7.
8. **Maintenance precedence**: `maintenance` only when no worse incident state is
   active; a full outage during maintenance reports `full_outage`.
9. **`degraded.json`** overall is `partial_outage` because severity derives from
   its `partial_outage` component — the fixture name describes the UI scenario.
10. **`unavailable.json`** models "nothing ever collected" with null sources (its
    documented shape) rather than a fake populated object.
11. **`generated_at`** uses second precision and `Z`, matching the SPEC sample.
