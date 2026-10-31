import Foundation

/// Human-readable clocks and durations shared by the app, the widget and the tests.
public enum ClockText {
    /// Formats a countdown as `H:MM:SS`; hours never wrap into days and negatives clamp to zero.
    public static func countdown(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00:00" }
        let whole = Int(max(0, seconds).rounded(.down))
        let hours = whole / 3_600
        let minutes = (whole % 3_600) / 60
        let remainder = whole % 60
        return "\(hours):" + String(format: "%02d:%02d", minutes, remainder)
    }

    /// Formats an elapsed/remaining interval as `"3h 12m"` or `"12m"` (floors to minutes).
    public static func away(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "0m" }
        let minutes = Int(max(0, interval / 60).rounded(.down))
        let hours = minutes / 60
        return hours != 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// Formats a window length as `"4h"`, `"2h 30m"` or `"30m"` (rounds to minutes).
    public static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "0m" }
        let minutes = Int(max(0, interval / 60).rounded())
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder)m" }
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}
