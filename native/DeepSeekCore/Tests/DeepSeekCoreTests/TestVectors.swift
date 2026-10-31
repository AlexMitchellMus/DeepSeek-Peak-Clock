import Foundation
import XCTest
@testable import DeepSeekCore

/// Typed access to `spec/vectors.json`, the source of truth shared by all implementations.
enum TestVectors {
    struct Payload: Decodable, Sendable {
        let switchMinutes: [Int]
        let weekendRuleStart: String
        let cnHolidays: [[String]]
        let instants: [Instant]
        let segments: [SegmentCase]
        let windows: [WindowCase]

        enum CodingKeys: String, CodingKey {
            case switchMinutes = "switch_minutes"
            case weekendRuleStart = "weekend_rule_start"
            case cnHolidays = "cn_holidays"
            case instants
            case segments
            case windows
        }
    }

    struct Instant: Decodable, Sendable {
        let t: String
        let kind: String
        let minuteOfDay: Int
        let windowStart: String
        let windowEnd: String
        let nextKind: String

        enum CodingKeys: String, CodingKey {
            case t
            case kind
            case minuteOfDay = "minute_of_day"
            case windowStart = "window_start"
            case windowEnd = "window_end"
            case nextKind = "next_kind"
        }
    }

    struct SegmentCase: Decodable, Sendable {
        let t: String
        let offsetMinutes: Int
        let segments: [Segment]

        enum CodingKeys: String, CodingKey {
            case t
            case offsetMinutes = "offset_minutes"
            case segments
        }
    }

    struct Segment: Decodable, Sendable {
        let start: Int
        let end: Int
        let kind: String
    }

    struct WindowCase: Decodable, Sendable {
        let t: String
        let count: Int
        let windows: [Window]
    }

    struct Window: Decodable, Sendable {
        let start: String
        let end: String
        let kind: String
        let current: Bool
    }

    /// Vectors parsed once per test process; fails loudly when the repo layout changes.
    static let shared: Payload = {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DeepSeekCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DeepSeekCore
            .deletingLastPathComponent() // native
            .deletingLastPathComponent() // repository root
        let url = repoRoot.appendingPathComponent("spec/vectors.json")
        do {
            return try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Could not load \(url.path): \(error)")
        }
    }()

    /// Parses an ISO-8601 timestamp from the vector file.
    static func date(_ iso8601: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso8601) else {
            fatalError("Unparseable vector timestamp: \(iso8601)")
        }
        return date
    }

    /// Parses a vector `kind` string.
    static func kind(_ raw: String) -> PriceKind {
        guard let kind = PriceKind(rawValue: raw) else {
            fatalError("Unparseable vector kind: \(raw)")
        }
        return kind
    }
}
