import Foundation
import XCTest
@testable import DeepSeekCore

final class PeakClockTests: XCTestCase {
    // MARK: - Vector parity

    func testConstantsMatchVectors() {
        XCTAssertEqual(PeakClock.switchMinutes, TestVectors.shared.switchMinutes)
        XCTAssertEqual(
            PeakClock.weekendRuleStart,
            TestVectors.date(TestVectors.shared.weekendRuleStart)
        )
        let expectedHolidays = TestVectors.shared.cnHolidays.compactMap { pair -> ClosedRange<String>? in
            guard pair.count == 2 else { return nil }
            return pair[0]...pair[1]
        }
        XCTAssertEqual(PeakClock.cnHolidays, expectedHolidays)
    }

    func testVectorFileHasTheExpectedShape() {
        XCTAssertEqual(TestVectors.shared.instants.count, 34, "spec/vectors.json must contain 34 instants")
        XCTAssertEqual(TestVectors.shared.windows.count, 3, "spec/vectors.json must contain 3 window cases")
    }

    func testInstantVectors() {
        for (index, vector) in TestVectors.shared.instants.enumerated() {
            let t = TestVectors.date(vector.t)
            let label = "instant #\(index + 1) (\(vector.t))"

            XCTAssertEqual(
                PeakClock.kind(at: t).rawValue,
                vector.kind,
                "\(label): kind"
            )
            XCTAssertEqual(
                PeakClock.minuteOfDayUTC(t),
                vector.minuteOfDay,
                "\(label): minute_of_day"
            )

            let window = PeakClock.window(at: t)
            XCTAssertEqual(
                window.start,
                TestVectors.date(vector.windowStart),
                "\(label): window_start"
            )
            XCTAssertEqual(
                window.end,
                TestVectors.date(vector.windowEnd),
                "\(label): window_end"
            )
            XCTAssertTrue(window.isCurrent, "\(label): window isCurrent")
            XCTAssertEqual(window.kind.rawValue, vector.kind, "\(label): window kind")

            let next = PeakClock.nextSwitches(after: t, count: 1)
            XCTAssertEqual(
                next.first?.date,
                TestVectors.date(vector.windowEnd),
                "\(label): next switch date"
            )
            XCTAssertEqual(
                next.first?.kind.rawValue,
                vector.nextKind,
                "\(label): next_kind"
            )
        }
    }

    // MARK: - Switch boundaries the vectors do not cover

    func testExactSwitchSecondBoundaries() {
        let cases: [(String, PriceKind)] = [
            ("2026-10-30T00:59:59Z", .off),
            ("2026-10-30T01:00:00Z", .peak),
            ("2026-10-30T03:59:59Z", .peak),
            ("2026-10-30T04:00:00Z", .off),
            ("2026-10-30T05:59:59Z", .off),
            ("2026-10-30T06:00:00Z", .peak),
            ("2026-10-30T09:59:59Z", .peak),
            ("2026-10-30T10:00:00Z", .off),
            ("2026-11-02T00:59:59Z", .off),
            ("2026-11-02T01:00:00Z", .peak)
        ]
        for (iso, expected) in cases {
            XCTAssertEqual(
                PeakClock.kind(at: TestVectors.date(iso)),
                expected,
                "kind at \(iso)"
            )
        }
    }

    func testSwitchInstantsExcludeAllDayOffDays() {
        // Friday 2026-10-30 switches are real: 01:00, 04:00, 06:00, 10:00 UTC.
        for iso in [
            "2026-10-30T01:00:00Z",
            "2026-10-30T04:00:00Z",
            "2026-10-30T06:00:00Z",
            "2026-10-30T10:00:00Z"
        ] {
            XCTAssertTrue(PeakClock.isSwitchInstant(TestVectors.date(iso)), "real switch \(iso)")
        }
        // Saturday 2026-10-31 and the National Day holiday switch minutes are suppressed.
        XCTAssertFalse(PeakClock.isSwitchInstant(TestVectors.date("2026-10-31T01:00:00Z")))
        XCTAssertFalse(PeakClock.isSwitchInstant(TestVectors.date("2026-10-05T06:00:00Z")))
        // Non-switch minutes are never switch instants.
        XCTAssertFalse(PeakClock.isSwitchInstant(TestVectors.date("2026-10-30T00:59:59Z")))
        XCTAssertFalse(PeakClock.isSwitchInstant(TestVectors.date("2026-10-30T02:00:00Z")))
    }

    func testWeekendRuleStartBoundary() {
        let justBefore = TestVectors.date("2026-08-22T15:59:59Z") // Beijing Sat 23:59
        let atRuleStart = TestVectors.date("2026-08-22T16:00:00Z") // Beijing Sun 00:00
        XCTAssertTrue(PeakClock.isBeijingWeekend(justBefore))
        XCTAssertFalse(PeakClock.offPeakAllDay(justBefore))
        XCTAssertTrue(PeakClock.offPeakAllDay(atRuleStart))
        XCTAssertFalse(PeakClock.isSwitchInstant(TestVectors.date("2026-08-23T01:00:00Z")))

        // A weekday after the rule start behaves normally.
        XCTAssertFalse(PeakClock.offPeakAllDay(TestVectors.date("2026-08-24T02:00:00Z")))
        XCTAssertEqual(PeakClock.kind(at: TestVectors.date("2026-08-24T02:00:00Z")), .peak)
    }

    func testHolidayBoundaries() {
        // Mid-Autumn: Beijing 2026-09-25 00:00 (2026-09-24T16:00Z) through 2026-09-27.
        XCTAssertFalse(PeakClock.isBeijingHoliday(TestVectors.date("2026-09-24T15:59:59Z")))
        XCTAssertTrue(PeakClock.isBeijingHoliday(TestVectors.date("2026-09-24T16:00:00Z")))
        XCTAssertTrue(PeakClock.isBeijingHoliday(TestVectors.date("2026-09-27T15:59:59Z")))
        XCTAssertFalse(PeakClock.isBeijingHoliday(TestVectors.date("2026-09-27T16:00:00Z")))
        XCTAssertFalse(PeakClock.offPeakAllDay(TestVectors.date("2026-09-27T16:00:00Z")))
        XCTAssertFalse(PeakClock.isSwitchInstant(TestVectors.date("2026-09-25T01:00:00Z")))

        // National Day: Beijing 2026-10-01 through 2026-10-07.
        XCTAssertTrue(PeakClock.isBeijingHoliday(TestVectors.date("2026-10-01T00:00:00Z")))
        XCTAssertTrue(PeakClock.isBeijingHoliday(TestVectors.date("2026-10-07T15:59:59Z")))
        XCTAssertFalse(PeakClock.isBeijingHoliday(TestVectors.date("2026-10-07T16:00:00Z")))
        XCTAssertEqual(PeakClock.kind(at: TestVectors.date("2026-10-03T06:30:00Z")), .off)

        // The first real switch after the holiday is 2026-10-08T01:00Z.
        XCTAssertTrue(PeakClock.isSwitchInstant(TestVectors.date("2026-10-08T01:00:00Z")))
        XCTAssertEqual(PeakClock.kind(at: TestVectors.date("2026-10-08T01:00:00Z")), .peak)
        XCTAssertEqual(
            PeakClock.currentWindowStart(TestVectors.date("2026-10-08T00:59:59Z")),
            TestVectors.date("2026-09-30T10:00:00Z")
        )
    }

    // MARK: - Derived helpers

    func testNextSwitchesAreStrictlyAfterTheInstant() {
        XCTAssertEqual(
            PeakClock.nextSwitches(after: TestVectors.date("2026-10-30T01:00:00Z"), count: 1)
                .first?.date,
            TestVectors.date("2026-10-30T04:00:00Z")
        )
        XCTAssertEqual(
            PeakClock.nextSwitches(after: TestVectors.date("2026-10-30T09:59:59Z"), count: 1)
                .first?.date,
            TestVectors.date("2026-10-30T10:00:00Z")
        )
        XCTAssertTrue(
            PeakClock.nextSwitches(after: TestVectors.date("2026-10-30T09:00:00Z"), count: 0).isEmpty
        )
        XCTAssertTrue(
            PeakClock.nextSwitches(after: TestVectors.date("2026-10-30T09:00:00Z"), count: -3).isEmpty
        )
    }

    func testWindowListIsContiguousAndStartsCurrent() {
        let now = TestVectors.date("2026-10-30T09:00:00Z")
        let windows = PeakClock.windows(at: now, count: 4)
        XCTAssertEqual(windows.count, 4)
        XCTAssertTrue(windows[0].isCurrent)
        XCTAssertFalse(windows[1].isCurrent)
        XCTAssertFalse(windows[2].isCurrent)
        XCTAssertFalse(windows[3].isCurrent)
        for index in 1..<windows.count {
            XCTAssertEqual(
                windows[index].start,
                windows[index - 1].end,
                "window \(index) must start where window \(index - 1) ends"
            )
            XCTAssertGreaterThan(windows[index].end, windows[index].start)
        }
        XCTAssertEqual(windows[0].start, TestVectors.date("2026-10-30T06:00:00Z"))
        XCTAssertEqual(windows[1].end, TestVectors.date("2026-11-02T01:00:00Z"))
        XCTAssertEqual(windows[1].kind, .off)
        XCTAssertTrue(PeakClock.windows(at: now, count: 0).isEmpty)
    }

    func testCountdownIsNeverNegative() {
        let t = TestVectors.date("2026-10-30T09:00:00Z")
        XCTAssertEqual(PeakClock.countdown(to: t, from: t), 0)
        XCTAssertEqual(PeakClock.countdown(to: t, from: t.addingTimeInterval(120)), 0)
        XCTAssertEqual(PeakClock.countdown(to: t, from: t.addingTimeInterval(-90)), 90)
        XCTAssertEqual(
            PeakClock.countdown(
                to: TestVectors.date("2026-10-30T10:00:00Z"),
                from: t
            ),
            3_600
        )
        XCTAssertGreaterThan(
            PeakClock.countdown(
                to: PeakClock.nextSwitches(after: t, count: 1)[0].date,
                from: t
            ),
            0
        )
    }

    func testMinuteOfDayUTC() {
        XCTAssertEqual(PeakClock.minuteOfDayUTC(TestVectors.date("2026-10-30T00:00:00Z")), 0)
        XCTAssertEqual(PeakClock.minuteOfDayUTC(TestVectors.date("2026-10-30T00:59:59Z")), 59)
        XCTAssertEqual(PeakClock.minuteOfDayUTC(TestVectors.date("2026-10-30T12:34:00Z")), 754)
        XCTAssertEqual(PeakClock.minuteOfDayUTC(TestVectors.date("2026-10-30T23:59:59Z")), 1_439)
    }
}
