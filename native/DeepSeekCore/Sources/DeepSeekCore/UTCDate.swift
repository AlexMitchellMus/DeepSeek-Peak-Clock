import Foundation

/// Internal, dependency-free UTC date math.
///
/// The public API never exposes a `Calendar`/`TimeZone`; every rule is evaluated
/// against absolute epoch seconds so daylight-saving transitions cannot alter it.
enum UTCDate {
    /// Seconds in one day; date math here is on fixed-length UTC days.
    static let secondsPerDay: Double = 86_400

    /// Gregorian calendar pinned to UTC.
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// Gregorian calendar pinned to Beijing time (UTC+8, no DST).
    static let beijingCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// The instant at which the Beijing weekend/holiday rule turns on: 2026-08-22T16:00:00Z.
    static let weekendRuleStart: Date = utcCalendar.date(
        from: DateComponents(year: 2026, month: 8, day: 22, hour: 16)
    )!

    /// UTC midnight of the day containing `date`.
    static func dayStart(_ date: Date) -> Date {
        let day = (date.timeIntervalSince1970 / secondsPerDay).rounded(.down)
        return Date(timeIntervalSince1970: day * secondsPerDay)
    }

    /// Minute of the UTC day containing `date`, in `0..<1440`.
    static func minuteOfDay(_ date: Date) -> Int {
        let minutes = (date.timeIntervalSince1970 / 60).rounded(.down)
        let wrapped = minutes.truncatingRemainder(dividingBy: 1_440)
        return Int(wrapped < 0 ? wrapped + 1_440 : wrapped)
    }

    /// `yyyy-MM-dd` of the Beijing calendar date containing `date`.
    static func beijingDateKey(_ date: Date) -> String {
        let parts = beijingCalendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    /// Whether the Beijing wall-clock weekday is Saturday or Sunday.
    static func isBeijingWeekend(_ date: Date) -> Bool {
        let weekday = beijingCalendar.component(.weekday, from: date) // 1 = Sunday, 7 = Saturday
        return weekday == 1 || weekday == 7
    }
}
