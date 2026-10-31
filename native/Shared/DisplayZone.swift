import Foundation

/// Localised labels for the card, computed against an explicit display offset so
/// previews, screenshots and widgets all agree regardless of the host time zone.
public enum DisplayZone {
    /// Minutes east of UTC for the display zone.
    public static func offsetMinutes(for date: Date) -> Int {
        TimeZone.current.secondsFromGMT(for: date) / 60
    }

    /// `"GMT+10:30"`, `"GMT-7"`, `"GMT"`.
    public static func label(offsetMinutes: Int) -> String {
        if offsetMinutes == 0 { return "GMT" }
        let sign = offsetMinutes > 0 ? "+" : "−"
        let abs = abs(offsetMinutes)
        let hours = abs / 60
        let minutes = abs % 60
        return "GMT\(sign)\(hours)" + (minutes == 0 ? "" : String(format: ":%02d", minutes))
    }

    /// A formatter pinned to an offset, using the current locale.
    public static func formatter(offsetMinutes: Int, format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60) ?? .gmt
        formatter.dateFormat = format
        return formatter
    }

    /// Calendar-day identity (yyyyMMdd) for a date in the display zone.
    public static func dayKey(_ date: Date, offsetMinutes: Int) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    /// Start of the display day (as an absolute instant) used by the 24 h bar.
    public static func dayStart(_ date: Date, offsetMinutes: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60) ?? .gmt
        return calendar.startOfDay(for: date)
    }

    /// Minute-of-display-day for an instant, 0..<1440.
    public static func minuteOfDay(_ date: Date, offsetMinutes: Int) -> Int {
        let shifted = date.timeIntervalSince(dayStart(date, offsetMinutes: offsetMinutes))
        return min(1439, max(0, Int(shifted / 60)))
    }

    /// `"3:30 PM"`, or `"Mon 3:30 PM"` when it is not today, or a dated label when
    /// the instant is six or more days away (weekend and holiday runs can be long).
    public static func switchLabel(_ date: Date, now: Date, offsetMinutes: Int) -> String {
        let far = abs(date.timeIntervalSince(now)) >= 6 * 86_400
        let sameDay = dayKey(date, offsetMinutes: offsetMinutes) == dayKey(now, offsetMinutes: offsetMinutes)
        if sameDay, !far {
            return formatter(offsetMinutes: offsetMinutes, format: "h:mm a").string(from: date)
        }
        let format = far ? "EEE, MMM d h:mm a" : "EEE h:mm a"
        return formatter(offsetMinutes: offsetMinutes, format: format).string(from: date)
    }

    /// Axis tick label for a minute of the display day, e.g. `"6 AM"`.
    public static func axisLabel(minute: Int, now: Date, offsetMinutes: Int) -> String {
        let instant = dayStart(now, offsetMinutes: offsetMinutes).addingTimeInterval(TimeInterval(minute * 60))
        return formatter(offsetMinutes: offsetMinutes, format: minute % 360 == 0 ? "h a" : "h:mm a")
            .string(from: instant)
    }

    /// Short weekday for the schedule bar's day, e.g. `"SAT"`.
    public static func weekdayLabel(_ date: Date, offsetMinutes: Int) -> String {
        formatter(offsetMinutes: offsetMinutes, format: "EEE").string(from: date).uppercased()
    }

    /// `"now · 3h 12m left"` for the current window, `"4h"` for the rest.
    public static func windowMeta(_ window: PriceWindow, now: Date) -> String {
        window.isCurrent
            ? "now · " + ClockText.away(window.end.timeIntervalSince(now)) + " left"
            : ClockText.duration(window.duration)
    }

    /// `"Mon 3:30 PM – Mon 6:30 AM"`, collapsing same-day ranges to two times.
    public static func range(_ start: Date, _ end: Date, now: Date, offsetMinutes: Int) -> String {
        let sameDay = dayKey(start, offsetMinutes: offsetMinutes) == dayKey(end, offsetMinutes: offsetMinutes)
        if sameDay {
            let time = formatter(offsetMinutes: offsetMinutes, format: "h:mm a")
            return time.string(from: start) + " – " + time.string(from: end)
        }
        let dayTime = formatter(offsetMinutes: offsetMinutes, format: "EEE h:mm a")
        return dayTime.string(from: start) + " – " + dayTime.string(from: end)
    }
}
