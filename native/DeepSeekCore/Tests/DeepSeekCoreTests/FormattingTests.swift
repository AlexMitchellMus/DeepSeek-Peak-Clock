import Foundation
import XCTest
@testable import DeepSeekCore

final class FormattingTests: XCTestCase {
    // MARK: - ClockText

    func testCountdownFormatting() {
        XCTAssertEqual(ClockText.countdown(0), "0:00:00")
        XCTAssertEqual(ClockText.countdown(59), "0:00:59")
        XCTAssertEqual(ClockText.countdown(60), "0:01:00")
        XCTAssertEqual(ClockText.countdown(3_599), "0:59:59")
        XCTAssertEqual(ClockText.countdown(3_600), "1:00:00")
        XCTAssertEqual(ClockText.countdown(205_960), "57:12:40") // 3-day weekend, hours never wrap
        XCTAssertEqual(ClockText.countdown(86_400), "24:00:00")
        XCTAssertEqual(ClockText.countdown(1.9), "0:00:01") // floors to whole seconds
        XCTAssertEqual(ClockText.countdown(-1), "0:00:00")
        XCTAssertEqual(ClockText.countdown(-10_000), "0:00:00")
        XCTAssertEqual(ClockText.countdown(.infinity), "0:00:00")
    }

    func testAwayFormatting() {
        XCTAssertEqual(ClockText.away(0), "0m")
        XCTAssertEqual(ClockText.away(59), "0m")
        XCTAssertEqual(ClockText.away(720), "12m")
        XCTAssertEqual(ClockText.away(3_599), "59m")
        XCTAssertEqual(ClockText.away(3_600), "1h 0m")
        XCTAssertEqual(ClockText.away(11_520), "3h 12m")
        XCTAssertEqual(ClockText.away(-30), "0m")
    }

    func testDurationFormatting() {
        XCTAssertEqual(ClockText.duration(0), "0m")
        XCTAssertEqual(ClockText.duration(1_800), "30m")
        XCTAssertEqual(ClockText.duration(3_600), "1h")
        XCTAssertEqual(ClockText.duration(9_000), "2h 30m")
        XCTAssertEqual(ClockText.duration(14_400), "4h")
        XCTAssertEqual(ClockText.duration(3_599), "1h") // rounds 59.98 min up to 60
        XCTAssertEqual(ClockText.duration(89), "1m")
        XCTAssertEqual(ClockText.duration(-5), "0m")
    }

    // MARK: - TrackerSnapshot

    func testSnapshotBundlesTheCurrentState() {
        let now = TestVectors.date("2026-10-30T09:00:00Z")
        let snapshot = TrackerSnapshot(now: now)

        XCTAssertEqual(snapshot.now, now)
        XCTAssertEqual(snapshot.kind, .peak)
        XCTAssertEqual(snapshot.window.start, TestVectors.date("2026-10-30T06:00:00Z"))
        XCTAssertEqual(snapshot.window.end, TestVectors.date("2026-10-30T10:00:00Z"))
        XCTAssertTrue(snapshot.window.isCurrent)
        XCTAssertEqual(snapshot.countdown, 3_600, accuracy: 1e-9)
        XCTAssertEqual(snapshot.countdownText, "1:00:00")
        XCTAssertEqual(snapshot.remainingText, "1h 0m")
        XCTAssertEqual(snapshot.nextSwitch?.date, TestVectors.date("2026-10-30T10:00:00Z"))
        XCTAssertEqual(snapshot.nextSwitch?.kind, .off)
    }

    func testSnapshotMatchesWindowAndSegmentVectors() {
        let snapshot = TrackerSnapshot(now: TestVectors.date("2026-10-30T09:00:00Z"))

        let vectorCase = TestVectors.shared.windows.first {
            $0.t == "2026-10-30T09:00:00Z" && $0.count == 4
        }
        XCTAssertNotNil(vectorCase)
        guard let vectorCase else { return }
        let windows = snapshot.windows(count: vectorCase.count)
        XCTAssertEqual(windows.count, vectorCase.windows.count)
        for (index, expected) in vectorCase.windows.enumerated() where index < windows.count {
            XCTAssertEqual(windows[index].start, TestVectors.date(expected.start), "window \(index) start")
            XCTAssertEqual(windows[index].end, TestVectors.date(expected.end), "window \(index) end")
            XCTAssertEqual(windows[index].kind.rawValue, expected.kind, "window \(index) kind")
            XCTAssertEqual(windows[index].isCurrent, expected.current, "window \(index) current")
        }

        let segmentCase = TestVectors.shared.segments.first {
            $0.t == "2026-10-30T09:00:00Z" && $0.offsetMinutes == 630
        }
        XCTAssertNotNil(segmentCase)
        guard let segmentCase else { return }
        let segments = snapshot.segments(offsetMinutes: 630)
        XCTAssertEqual(segments.count, segmentCase.segments.count)
        for (index, expected) in segmentCase.segments.enumerated() where index < segments.count {
            XCTAssertEqual(segments[index].startMinute, expected.start)
            XCTAssertEqual(segments[index].endMinute, expected.end)
            XCTAssertEqual(segments[index].kind.rawValue, expected.kind)
        }
    }

    func testSnapshotCountdownNeverNegative() {
        let oneSecondBeforeSwitch = TrackerSnapshot(now: TestVectors.date("2026-10-30T00:59:59Z"))
        XCTAssertEqual(oneSecondBeforeSwitch.countdown, 1, accuracy: 1e-9)
        XCTAssertEqual(oneSecondBeforeSwitch.countdownText, "0:00:01")

        let farFuture = TrackerSnapshot(now: TestVectors.date("2026-10-30T09:00:00Z"))
        XCTAssertGreaterThanOrEqual(farFuture.countdown, 0)
    }
}
