import Foundation
import XCTest
@testable import DeepSeekCore

final class SegmentTests: XCTestCase {
    // MARK: - Vector parity

    func testVectorFileHasTheExpectedShape() {
        // Grows when vectors gain a case (see spec/vectors.mjs); keeps the file honest.
        XCTAssertEqual(TestVectors.shared.segments.count, 8, "spec/vectors.json must contain 8 segment cases")
    }

    func testSegmentVectors() {
        for (index, vector) in TestVectors.shared.segments.enumerated() {
            let label = "segment case #\(index + 1) (t: \(vector.t), offset: \(vector.offsetMinutes))"
            let actual = PeakClock.displaySegments(
                at: TestVectors.date(vector.t),
                offsetMinutes: vector.offsetMinutes
            )
            XCTAssertEqual(actual.count, vector.segments.count, "\(label): segment count")
            for (segmentIndex, expected) in vector.segments.enumerated() where segmentIndex < actual.count {
                XCTAssertEqual(
                    actual[segmentIndex].startMinute,
                    expected.start,
                    "\(label): segment \(segmentIndex) start"
                )
                XCTAssertEqual(
                    actual[segmentIndex].endMinute,
                    expected.end,
                    "\(label): segment \(segmentIndex) end"
                )
                XCTAssertEqual(
                    actual[segmentIndex].kind.rawValue,
                    expected.kind,
                    "\(label): segment \(segmentIndex) kind"
                )
            }
        }
    }

    // MARK: - Structural invariants

    func testSegmentsTileTheWholeDisplayDay() {
        let instants = [
            "2026-10-30T09:00:00Z", // normal weekday
            "2026-10-31T09:00:00Z", // Beijing Saturday
            "2026-10-05T03:00:00Z", // National Day holiday
            "2026-09-24T09:00:00Z" // holiday eve
        ]
        // Offsets in minutes east of UTC, including +630 and -420.
        let offsets = [-720, -660, -420, 0, 330, 630, 840]
        for iso in instants {
            for offset in offsets {
                let segments = PeakClock.displaySegments(
                    at: TestVectors.date(iso),
                    offsetMinutes: offset
                )
                let label = "segments at \(iso), offset \(offset)"
                XCTAssertFalse(segments.isEmpty, "\(label): non-empty")
                XCTAssertEqual(segments.first?.startMinute, 0, "\(label): starts at 0")
                XCTAssertEqual(segments.last?.endMinute, 1_440, "\(label): ends at 1440")
                for (index, segment) in segments.enumerated() {
                    XCTAssertGreaterThan(segment.endMinute, segment.startMinute, "\(label): segment \(index) is not empty")
                    if index > 0 {
                        XCTAssertEqual(
                            segment.startMinute,
                            segments[index - 1].endMinute,
                            "\(label): segment \(index) must continue segment \(index - 1)"
                        )
                        XCTAssertNotEqual(
                            segment.kind,
                            segments[index - 1].kind,
                            "\(label): adjacent segments must have different kinds"
                        )
                    }
                }
            }
        }
    }

    func testSegmentsUseTheDisplayZonesCalendarDay() {
        // +630: 20:52Z Friday is 07:22 Saturday. Saturday is off-peak all
        // day, so the bar must be one green run — not Friday's peaks.
        let saturday = PeakClock.displaySegments(
            at: TestVectors.date("2026-10-30T20:52:00Z"),
            offsetMinutes: 630
        )
        XCTAssertEqual(saturday.count, 1, "a weekend day is a single off-peak run")
        XCTAssertEqual(saturday.first?.kind, .off)
        XCTAssertEqual(saturday.first?.startMinute, 0)
        XCTAssertEqual(saturday.first?.endMinute, 1_440)

        // Same local day, 16 hours apart → identical bars.
        let laterSaturday = PeakClock.displaySegments(
            at: TestVectors.date("2026-10-31T12:52:00Z"),
            offsetMinutes: 630
        )
        XCTAssertEqual(saturday, laterSaturday, "the bar is keyed to the local date")

        // US Pacific (-420): 03:00Z Saturday is 20:00 Friday, which still shows
        // Friday's peak windows.
        let friday = PeakClock.displaySegments(
            at: TestVectors.date("2026-10-31T03:00:00Z"),
            offsetMinutes: -420
        )
        XCTAssertEqual(friday.first?.kind, .peak)
        XCTAssertEqual(friday.last?.endMinute, 1_440)
    }

    func testKnownDisplayBoundaries() {
        // At +630 on a normal weekday: switch minutes appear at 690/870/990/1230.
        let adelaide = PeakClock.displaySegments(
            at: TestVectors.date("2026-10-30T09:00:00Z"),
            offsetMinutes: 630
        )
        XCTAssertEqual(
            adelaide.map(\.startMinute),
            [0, 690, 870, 990, 1_230]
        )
        // US Pacific (-420) wraps the afternoon peak to the start of the local day.
        let pacific = PeakClock.displaySegments(
            at: TestVectors.date("2026-10-30T09:00:00Z"),
            offsetMinutes: -420
        )
        XCTAssertEqual(
            pacific.map(\.startMinute),
            [0, 180]
        )
        XCTAssertEqual(pacific.first?.kind, .peak)
        XCTAssertEqual(pacific.last?.kind, .off)
    }

    func testAllOffDayCollapsesToASingleSegment() {
        let segments = PeakClock.displaySegments(
            at: TestVectors.date("2026-10-05T03:00:00Z"),
            offsetMinutes: 0
        )
        XCTAssertEqual(
            segments,
            [TimelineSegment(startMinute: 0, endMinute: 1_440, kind: .off)]
        )
    }
}
