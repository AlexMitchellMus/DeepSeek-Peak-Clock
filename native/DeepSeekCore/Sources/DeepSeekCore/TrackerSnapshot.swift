import Foundation

/// A single immutable read of the price clock, ready for a SwiftUI view or a widget entry.
///
/// The snapshot owns no timers and no global state: the caller supplies `now` (usually once
/// per second) and derives everything else from it.
public struct TrackerSnapshot: Sendable {
    /// Reference instant this snapshot describes.
    public let now: Date
    /// Price kind at `now`.
    public let kind: PriceKind
    /// Current price window containing `now`.
    public let window: PriceWindow
    /// First real price switch after `now`, when one exists.
    public let nextSwitch: (date: Date, kind: PriceKind)?

    /// Creates a snapshot for `now`.
    public init(now: Date = Date()) {
        self.now = now
        self.kind = PeakClock.kind(at: now)
        self.window = PeakClock.window(at: now)
        self.nextSwitch = PeakClock.nextSwitches(after: now, count: 1).first
    }

    /// Seconds remaining in the current window, never negative.
    public var countdown: TimeInterval {
        PeakClock.countdown(to: window.end, from: now)
    }

    /// Current-window countdown formatted as `H:MM:SS`, e.g. `"57:12:40"`.
    public var countdownText: String {
        ClockText.countdown(countdown)
    }

    /// Remaining time in the current window formatted as `"3h 12m"`.
    public var remainingText: String {
        ClockText.away(countdown)
    }

    /// The next `count` price windows, current window first.
    public func windows(count: Int = 4) -> [PriceWindow] {
        PeakClock.windows(at: now, count: count)
    }

    /// The 24-hour timeline for a display zone `offsetMinutes` east of UTC.
    public func segments(offsetMinutes: Int = 0) -> [TimelineSegment] {
        PeakClock.displaySegments(at: now, offsetMinutes: offsetMinutes)
    }
}
