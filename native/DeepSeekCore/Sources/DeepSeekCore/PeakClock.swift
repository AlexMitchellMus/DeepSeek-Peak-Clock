import Foundation

/// The 2026 DeepSeek peak/off-peak clock (SPEC.md §2), evaluated entirely in UTC.
///
/// A weekday is split into peak windows `01:00–04:00` and `06:00–10:00` UTC; everything
/// else is off-peak. From 2026-08-22T16:00Z onward, Beijing weekends and the listed
/// Chinese public holidays are off-peak all day, which suppresses their switch instants.
public enum PeakClock {
    /// UTC minute-of-day values at which a price switch can occur: 01:00, 04:00, 06:00, 10:00.
    public static let switchMinutes: [Int] = [60, 240, 360, 600]

    /// First instant the Beijing weekend/holiday rule applies: 2026-08-22T16:00:00Z.
    public static let weekendRuleStart: Date = UTCDate.weekendRuleStart

    /// Inclusive Beijing-date (`yyyy-MM-dd`) ranges billed off-peak all day.
    public static let cnHolidays: [ClosedRange<String>] = [
        "2026-09-25"..."2026-09-27", // Mid-Autumn
        "2026-10-01"..."2026-10-07" // National Day
    ]

    /// Minute of the UTC day containing `date`, in `0..<1440`.
    public static func minuteOfDayUTC(_ date: Date) -> Int {
        UTCDate.minuteOfDay(date)
    }

    /// Whether the Beijing wall-clock weekday at `date` is Saturday or Sunday.
    public static func isBeijingWeekend(_ date: Date) -> Bool {
        UTCDate.isBeijingWeekend(date)
    }

    /// Whether the Beijing calendar date at `date` falls inside `cnHolidays`.
    public static func isBeijingHoliday(_ date: Date) -> Bool {
        let key = UTCDate.beijingDateKey(date)
        return cnHolidays.contains { $0.contains(key) }
    }

    /// Whether the all-day off-peak rule (Chinese weekend or public holiday) applies at `date`.
    public static func offPeakAllDay(_ date: Date) -> Bool {
        date >= weekendRuleStart && (isBeijingWeekend(date) || isBeijingHoliday(date))
    }

    /// Price kind at `date`.
    public static func kind(at date: Date) -> PriceKind {
        if offPeakAllDay(date) { return .off }
        let minute = minuteOfDayUTC(date)
        if (60..<240).contains(minute) || (360..<600).contains(minute) { return .peak }
        return .off
    }

    /// Whether `date` is a real price switch: a switch minute that is not on an all-day off day.
    public static func isSwitchInstant(_ date: Date) -> Bool {
        guard switchMinutes.contains(minuteOfDayUTC(date)) else { return false }
        return !offPeakAllDay(date)
    }

    /// The first `count` real switch instants strictly after `date`, in ascending order.
    public static func nextSwitches(after date: Date, count: Int) -> [(date: Date, kind: PriceKind)] {
        guard count > 0 else { return [] }
        let now = date.timeIntervalSince1970
        let dayStart = (now / UTCDate.secondsPerDay).rounded(.down) * UTCDate.secondsPerDay
        var result: [(date: Date, kind: PriceKind)] = []
        result.reserveCapacity(count)
        var day = 0
        var index = 0
        // A real switch is never more than ~8 days away; the day cap only guards
        // pathological `count` values against an endless loop.
        while result.count < count && day < 4_000 {
            let instant = dayStart
                + Double(day) * UTCDate.secondsPerDay
                + Double(switchMinutes[index]) * 60
            if instant > now {
                let candidate = Date(timeIntervalSince1970: instant)
                if isSwitchInstant(candidate) {
                    result.append((candidate, kind(at: candidate)))
                }
            }
            index += 1
            if index == switchMinutes.count {
                index = 0
                day += 1
            }
        }
        return result
    }

    /// Start of the window containing `date`: the most recent real switch instant at or before it.
    public static func currentWindowStart(_ date: Date) -> Date {
        let now = date.timeIntervalSince1970
        let dayStart = (now / UTCDate.secondsPerDay).rounded(.down) * UTCDate.secondsPerDay
        var best: Double?
        for day in -21...0 {
            for minute in switchMinutes {
                let instant = dayStart
                    + Double(day) * UTCDate.secondsPerDay
                    + Double(minute) * 60
                guard instant <= now else { continue }
                if let previous = best, instant <= previous { continue }
                if isSwitchInstant(Date(timeIntervalSince1970: instant)) {
                    best = instant
                }
            }
        }
        return Date(timeIntervalSince1970: best ?? (now - UTCDate.secondsPerDay))
    }

    /// The current price window: starts at the most recent real switch, ends at the next one.
    public static func window(at date: Date) -> PriceWindow {
        let start = currentWindowStart(date)
        let end = nextSwitches(after: date, count: 1).first?.date
            ?? start.addingTimeInterval(UTCDate.secondsPerDay)
        return PriceWindow(start: start, end: end, kind: kind(at: date), isCurrent: true)
    }

    /// `count` consecutive price windows, the current window first.
    public static func windows(at date: Date, count: Int) -> [PriceWindow] {
        guard count > 0 else { return [] }
        let upcoming = nextSwitches(after: date, count: count)
        var start = currentWindowStart(date)
        var currentKind = kind(at: date)
        var result: [PriceWindow] = []
        result.reserveCapacity(upcoming.count)
        for (index, next) in upcoming.enumerated() {
            result.append(
                PriceWindow(start: start, end: next.date, kind: currentKind, isCurrent: index == 0)
            )
            start = next.date
            currentKind = next.kind
        }
        return result
    }

    /// The 24-hour display timeline for a zone `offsetMinutes` east of UTC.
    ///
    /// Boundaries are the display-day edges, every switch minute, and Beijing midnight
    /// (960 UTC), all shifted into the display day and wrapped into `0..<1440`. Each
    /// slice is sampled at its midpoint, and adjacent slices of equal kind are merged.
    public static func displaySegments(at date: Date, offsetMinutes: Int = 0) -> [TimelineSegment] {
        let offset = Double(offsetMinutes)
        // Anchor on the display zone's calendar day: east of UTC the local date can be
        // a day ahead of the UTC date (20:52Z Friday is 07:22 Saturday at +10:30).
        let shifted = date.timeIntervalSince1970 + offset * 60
        let shiftedMidnight = (shifted / UTCDate.secondsPerDay).rounded(.down) * UTCDate.secondsPerDay
        let dayStart = shiftedMidnight - offset * 60

        var boundaries: [Int] = [0, 1_440]
        for minute in switchMinutes {
            boundaries.append(wrappedMinute(minute + offsetMinutes))
        }
        boundaries.append(wrappedMinute(960 + offsetMinutes)) // Beijing midnight
        boundaries.sort()

        var raw: [(start: Int, end: Int, kind: PriceKind)] = []
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            guard end > start else { continue }
            let sample = Date(timeIntervalSince1970: dayStart + (Double(start) + 0.5) * 60)
            raw.append((start, end, kind(at: sample)))
        }

        var merged: [TimelineSegment] = []
        for segment in raw {
            if let last = merged.last, last.kind == segment.kind {
                merged[merged.count - 1] = TimelineSegment(
                    startMinute: last.startMinute,
                    endMinute: segment.end,
                    kind: last.kind
                )
            } else {
                merged.append(
                    TimelineSegment(startMinute: segment.start, endMinute: segment.end, kind: segment.kind)
                )
            }
        }
        return merged
    }

    /// Seconds from `now` until `date`, clamped to zero.
    public static func countdown(to date: Date, from now: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(now))
    }

    /// Wraps a minute value into `0..<1440`.
    private static func wrappedMinute(_ minute: Int) -> Int {
        let wrapped = minute % 1_440
        return wrapped < 0 ? wrapped + 1_440 : wrapped
    }
}
