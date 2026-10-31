# DeepSeekCore — Swift core

The shared Swift engine for the native app (`native/App/`) and the WidgetKit extension
(`native/Widget/`). Foundation only — no SwiftUI, AppKit, UIKit, no third-party packages, no
timers, no singletons. Everything is a pure function of the instant you pass in, so it is safe
to use from a SwiftUI view, a widget timeline entry, or a Swift 6 concurrency task.

| Item | Value |
| --- | --- |
| Package | `native/DeepSeekCore` (SwiftPM, `swift-tools-version:5.9`) |
| Product / module | `DeepSeekCore` (library) |
| Platform | macOS 14+ |
| Sources | `native/DeepSeekCore/Sources/DeepSeekCore/*.swift` |
| Tests | `native/DeepSeekCore/Tests/DeepSeekCoreTests/*.swift` |
| Contract | `SPEC.md` §2 (timing), §3 (pricing), §4 (metrics); vectors in `spec/vectors.json` |

The engine is a 1:1 port of `spec/reference-clock.mjs` and reproduces all 34 instants, 6
timeline-segment cases and 3 window-list cases in `spec/vectors.json`.

## Running the tests

SwiftPM cannot use the sandboxed default caches in this repo, so always build/test like this:

```sh
cd native/DeepSeekCore
mkdir -p ../../.tmp/hc ../../.tmp/mc
export TMPDIR="$PWD/../../.tmp/hc"
export CLANG_MODULE_CACHE_PATH="$PWD/../../.tmp/mc"
swift test --disable-sandbox --cache-path ../../.tmp/cc --scratch-path ../../.tmp/cc
```

Result on the reference machine: **39 tests, 0 failures, ~2 s wall clock** (test execution
itself is ~0.05 s). The vector file is located from `#filePath`
(`…/native/DeepSeekCore/Tests/DeepSeekCoreTests/X.swift` → up five levels to the repo root), so
the package must stay in that directory layout. The suite also compiles cleanly with
`-strict-concurrency=complete -warnings-as-errors` and in Swift 6 language mode.

## Peak clock (SPEC §2)

All math is absolute UTC epoch seconds; the Beijing calendar is a fixed UTC+8 offset, so there
are no daylight-saving surprises anywhere.

* **Switch minutes** — the price may only change at UTC minutes-of-day
  `[60, 240, 360, 600]` (01:00, 04:00, 06:00, 10:00).
* **Peak ranges** — peak iff the minute-of-day is in `[60, 240)` or `[360, 600)`, i.e.
  01:00–04:00 and 06:00–10:00 UTC. Everything else is off-peak.
* **Weekend/holiday rule** — only instants **at or after** `2026-08-22T16:00:00Z`
  (Beijing Sunday 2026-08-23 00:00) are affected. On those instants, if the Beijing
  wall-clock day is Saturday or Sunday, **or** the Beijing date is inside one of
  `cnHolidays` (`2026-09-25…2026-09-27`, `2026-10-01…2026-10-07`, inclusive strings in
  `yyyy-MM-dd`), the whole day is off-peak (`offPeakAllDay`).
* **Switch suppression** — a switch minute on an all-day-off day is not a real price change.
  This merges Friday 16:00Z through Monday 01:00Z into one long off-peak run, and likewise
  merges the National Day holiday into one window (2026-09-30 10:00Z → 2026-10-08 01:00Z).
* **Windows** — `currentWindowStart(now)` scans the last 21 days for the most recent *real*
  switch (falling back to `now − 24h` if there is none); `nextSwitches(after:count:)` scans
  forward for real switches strictly after `now`. A window is `[start, end)`; its kind is the
  kind at `now`, and `window(at:).isCurrent` is `true`.
* **Display timeline** — `displaySegments(at:offsetMinutes:)` builds the 24-hour bar for a
  zone `offsetMinutes` east of UTC (`+630`, `-420`, …). Boundaries are
  `0`, `1440`, every switch minute, and **Beijing midnight (UTC minute 960)**, each shifted by
  the offset and wrapped into `[0, 1440)`. Each slice is sampled at its midpoint to decide its
  kind (so weekend/holiday rules apply correctly), then adjacent slices of equal kind are
  merged. The result always tiles `0..<1440` with no gaps, and adjacent segments always
  differ in kind. `offsetMinutes: 0` is the UTC bar.
* **Countdown** — `countdown(to:from:)` is `max(0, to − from)`, so it can never go negative.

Public surface:

```swift
public enum PeakClock {
    public static let switchMinutes: [Int]                              // [60, 240, 360, 600]
    public static let weekendRuleStart: Date                            // 2026-08-22T16:00Z
    public static let cnHolidays: [ClosedRange<String>]                 // Beijing yyyy-MM-dd

    public static func minuteOfDayUTC(_ date: Date) -> Int
    public static func isBeijingWeekend(_ date: Date) -> Bool
    public static func isBeijingHoliday(_ date: Date) -> Bool
    public static func offPeakAllDay(_ date: Date) -> Bool
    public static func kind(at date: Date) -> PriceKind
    public static func isSwitchInstant(_ date: Date) -> Bool
    public static func nextSwitches(after date: Date, count: Int) -> [(date: Date, kind: PriceKind)]
    public static func currentWindowStart(_ date: Date) -> Date
    public static func window(at date: Date) -> PriceWindow             // start <= now, end = next switch
    public static func windows(at date: Date, count: Int) -> [PriceWindow]
    public static func displaySegments(at date: Date, offsetMinutes: Int = 0) -> [TimelineSegment]
    public static func countdown(to date: Date, from now: Date) -> TimeInterval
}
```

`PriceKind` is `.peak` / `.off`; `PriceWindow` carries `start`, `end`, `kind`, `isCurrent`
and `id == start`; `TimelineSegment` carries display `startMinute`/`endMinute` and `kind`, with
`id == startMinute`.

## Pricing (SPEC §3)

`PriceTable.rows` is the rate card in USD per 1M tokens, Flash first:

| Model | input off → peak | cached input off → peak | output off → peak |
| --- | --- | --- | --- |
| DeepSeek V4.1 Flash | $0.15 → $0.30 | $0.003 → $0.006 | $0.60 → $1.20 |
| DeepSeek V4 Pro | $0.66 → $1.32 | $0.022 → $0.044 | $1.98 → $3.96 |

Peak is always exactly twice off-peak (`Price(off:)` derives `peak`), and
`PriceTable.formatted(_:)` renders `"$0.003"`, `"$1.20"`, `"$3.96"`: three decimals when the
third decimal is significant, otherwise two. Rows expose `price(_ bucket:)` and
`formatted(_ bucket, kind:)`; `Bucket` is `.input`, `.cachedInput`, `.output`.
`PriceTable.webSearchFootnote` carries the `$0.75 / 1K requests` footnote.

## Formatting

```swift
public enum ClockText {
    public static func countdown(_ seconds: TimeInterval) -> String  // "57:12:40" (hours never wrap)
    public static func away(_ interval: TimeInterval) -> String      // "3h 12m" / "12m" (floor to minutes)
    public static func duration(_ interval: TimeInterval) -> String  // "4h" / "2h 30m" / "30m" (round)
}
```

`countdown` floors to whole seconds and clamps negatives to `0:00:00`; `away` floors to
minutes; `duration` rounds to minutes and drops a trailing `0m`.

## Metrics (`metrics/metrics.json`, schema v1)

```swift
public struct TrackerMetrics: Codable, Sendable {
    public var schema: Int?
    public var generatedAt: Date?
    public var source: String?
    public var overall: MetricsStatus          // .operational/.degraded/.partialOutage/
    public var statusLabel: String?            //  .fullOutage/.maintenance/.unknown
    public var components: [ComponentMetrics]
    public var activeIncidents: Int
    public var latency: LatencyMetrics?
    public var balance: BalanceMetrics?
    public var error: String?
    public var warnings: [String]

    public func age(now: Date) -> TimeInterval       // .infinity without generated_at
    public func freshness(now: Date) -> Freshness    // .live / .stale / .unavailable
    public var displayStatus: String                 // statusLabel ?? overall.displayName
    public static func decode(_ data: Data) throws -> TrackerMetrics
}
```

Decoding is deliberately lenient: missing keys, `null`, malformed nested objects and arrays of
the wrong type never throw. Unknown status strings become `.unknown`, numeric strings
(`"214"`, `"99.5"`) decode as numbers, booleans accept `true` / `"true"` / `1`, and timestamps
accept ISO-8601 with or without fractional seconds (or epoch seconds). A decoded payload with
`generatedAt == nil` reports `.unavailable`.

Freshness follows SPEC §4: `age < 2 min` → `.live`; `2…15 min` → `.stale` (render dimmed with
the age); `> 15 min` or no `generated_at` → `.unavailable`. `.loading` exists for the caller's
"no payload yet" state and is never returned by `freshness(now:)`.

## One value for a view: `TrackerSnapshot`

```swift
public struct TrackerSnapshot: Sendable {
    public let now: Date
    public let kind: PriceKind
    public let window: PriceWindow
    public let nextSwitch: (date: Date, kind: PriceKind)?
    public var countdown: TimeInterval
    public var countdownText: String          // "57:12:40"
    public var remainingText: String          // "3h 12m"
    public init(now: Date = Date())
    public func windows(count: Int = 4) -> [PriceWindow]
    public func segments(offsetMinutes: Int = 0) -> [TimelineSegment]
}
```

It is a plain immutable value — no timers, no singletons — so a SwiftUI view can take one
snapshot and render everything, and a widget can build one per timeline entry.

## How the app uses it

Add the seven source files to **both** the app target and the WidgetKit extension target
(Compile Sources). Do **not** add `import DeepSeekCore` to those files or to callers when the
files are compiled directly into the targets — they are plain source files that compile in
place. (Alternatively link the `DeepSeekCore` library product from the Xcode project and use
the module; pick one, never both, or the symbols will be duplicated.)

```swift
import SwiftUI
import WidgetKit

struct PriceClockView: View {
    let snapshot: TrackerSnapshot
    let metrics: TrackerMetrics
    let offsetMinutes: Int   // TimeZone.current.secondsFromGMT(for: snapshot.now) / 60

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.kind == .peak ? "Peak" : "Off-peak")
            Text(snapshot.countdownText)                 // "57:12:40"
                .font(.system(.title, design: .monospaced))
            if let next = snapshot.nextSwitch {
                Text("Switch \(next.kind == .peak ? "to peak" : "to off-peak") in \(ClockText.away(next.date.timeIntervalSince(snapshot.now)))")
            }

            TimelineBar(segments: snapshot.segments(offsetMinutes: offsetMinutes))

            ForEach(snapshot.windows(count: 4)) { window in
                HStack {
                    Text(window.kind == .peak ? "Peak" : "Off-peak")
                    Text(ClockText.duration(window.duration))
                    if window.isCurrent { Text("now") }
                }
            }

            Text(metrics.displayStatus)                  // "All systems operational"
            Text("\(ClockText.away(metrics.age(now: snapshot.now))) ago")
        }
    }
}

// Widget entry point: one snapshot per timeline entry; the core stays pure.
struct TrackerEntry: TimelineEntry {
    let date: Date
    let snapshot: TrackerSnapshot
    let metrics: TrackerMetrics
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> TrackerEntry {
        TrackerEntry(date: Date(), snapshot: TrackerSnapshot(), metrics: TrackerMetrics())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrackerEntry>) -> Void) {
        let now = Date()
        let data = try? Data(contentsOf: metricsURL)   // app-group metrics.json
        let entry = TrackerEntry(
            date: now,
            snapshot: TrackerSnapshot(now: now),
            metrics: (try? TrackerMetrics.decode(data ?? Data())) ?? TrackerMetrics()
        )
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(60))))
    }
}
```

Tips:

* Recompute `TrackerSnapshot(now:)` once per tick (1 Hz in the app, per timeline entry in the
  widget); everything else is derived.
* `offsetMinutes` for the local bar: `TimeZone.current.secondsFromGMT(for: now) / 60`. Compute
  it per instant, not once per day, if you care about DST transitions.
* The current window meta line is `now · \(snapshot.remainingText) left`; other rows are
  `ClockText.duration(window.duration)`.
* Everything public is `Sendable`; the package builds cleanly with Swift 6 strict concurrency,
  so it can be passed across `@MainActor` boundaries or into widget timelines without
  warnings.
