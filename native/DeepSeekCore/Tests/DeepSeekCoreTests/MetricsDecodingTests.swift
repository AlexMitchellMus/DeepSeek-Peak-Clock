import Foundation
import XCTest
@testable import DeepSeekCore

final class MetricsDecodingTests: XCTestCase {
    private let generatedAtJSON = #"{"generated_at":"2026-10-30T09:12:00Z"}"#

    private var generatedAt: Date {
        TestVectors.date("2026-10-30T09:12:00Z")
    }

    private func decode(_ json: String) throws -> TrackerMetrics {
        try TrackerMetrics.decode(Data(json.utf8))
    }

    // MARK: - Full fixture

    func testDecodesFullPayload() throws {
        let metrics = try decode(
            #"""
            {
              "schema": 1,
              "generated_at": "2026-10-30T09:12:00Z",
              "source": "status.deepseek.com",
              "status": {
                "overall": "operational",
                "label": "All systems operational",
                "components": [
                  {"id": "01KY", "name": "DeepSeek V4.1 Flash API", "status": "operational", "uptime": 99.85},
                  {"id": "02KY", "name": "DeepSeek V4 Pro API", "status": "degraded", "uptime": null}
                ],
                "active_incidents": 1
              },
              "latency": {
                "ok": true, "ms": 214, "p50_ms": 198, "samples": 5,
                "endpoint": "api.deepseek.com", "checked_at": "2026-10-30T09:12:00Z"
              },
              "balance": {
                "available": true, "currency": "USD", "total": 12.34,
                "top_up": 10.0, "granted": 2.34, "key_hint": "sk-abcd"
              },
              "error": null,
              "warnings": ["status page parsed from fallback payload"]
            }
            """#
        )

        XCTAssertEqual(metrics.schema, 1)
        XCTAssertEqual(metrics.generatedAt, generatedAt)
        XCTAssertEqual(metrics.source, "status.deepseek.com")
        XCTAssertEqual(metrics.overall, .operational)
        XCTAssertEqual(metrics.statusLabel, "All systems operational")
        XCTAssertEqual(metrics.displayStatus, "All systems operational")
        XCTAssertEqual(metrics.activeIncidents, 1)
        XCTAssertNil(metrics.error)
        XCTAssertEqual(metrics.warnings, ["status page parsed from fallback payload"])

        XCTAssertEqual(metrics.components.count, 2)
        XCTAssertEqual(metrics.components[0].id, "01KY")
        XCTAssertEqual(metrics.components[0].name, "DeepSeek V4.1 Flash API")
        XCTAssertEqual(metrics.components[0].status, .operational)
        XCTAssertEqual(try XCTUnwrap(metrics.components[0].uptime), 99.85, accuracy: 1e-12)
        XCTAssertEqual(metrics.components[1].status, .degraded)
        XCTAssertNil(metrics.components[1].uptime)

        XCTAssertEqual(metrics.latency?.ok, true)
        XCTAssertEqual(metrics.latency?.milliseconds, 214)
        XCTAssertEqual(metrics.latency?.p50Milliseconds, 198)
        XCTAssertEqual(metrics.latency?.samples, 5)
        XCTAssertEqual(metrics.latency?.endpoint, "api.deepseek.com")
        XCTAssertEqual(metrics.latency?.checkedAt, generatedAt)

        XCTAssertEqual(metrics.balance?.available, true)
        XCTAssertEqual(metrics.balance?.currency, "USD")
        let balance = try XCTUnwrap(metrics.balance)
        XCTAssertEqual(try XCTUnwrap(balance.total), 12.34, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(balance.topUp), 10.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(balance.granted), 2.34, accuracy: 1e-12)
        XCTAssertEqual(metrics.balance?.keyHint, "sk-abcd")
    }

    func testRoundTripsThroughCodable() throws {
        let original = try decode(
            #"""
            {"schema":1,"generated_at":"2026-10-30T09:12:00Z","source":"status.deepseek.com",
             "status":{"overall":"partial_outage","label":"Partial outage",
               "components":[{"id":"a","name":"API","status":"degraded","uptime":98.5}],
               "active_incidents":2},
             "latency":{"ok":true,"ms":214,"p50_ms":198,"samples":5,"endpoint":"api.deepseek.com",
               "checked_at":"2026-10-30T09:12:00Z"},
             "balance":{"available":true,"currency":"USD","total":12.34,"top_up":10,"granted":2.34,"key_hint":"sk-abcd"},
             "warnings":["w"]}
            """#
        )
        let decoded = try TrackerMetrics.decode(try JSONEncoder().encode(original))
        XCTAssertEqual(decoded.generatedAt, original.generatedAt)
        XCTAssertEqual(decoded.overall, original.overall)
        XCTAssertEqual(decoded.statusLabel, original.statusLabel)
        XCTAssertEqual(decoded.activeIncidents, original.activeIncidents)
        XCTAssertEqual(decoded.components.count, original.components.count)
        XCTAssertEqual(decoded.components[0].status, original.components[0].status)
        XCTAssertEqual(decoded.latency?.checkedAt, original.latency?.checkedAt)
        XCTAssertEqual(decoded.latency?.milliseconds, original.latency?.milliseconds)
        XCTAssertEqual(decoded.balance?.total, original.balance?.total)
        XCTAssertEqual(decoded.warnings, original.warnings)
    }

    // MARK: - Leniency

    func testEmptyObjectDecodesToDefaults() throws {
        let metrics = try decode("{}")
        XCTAssertNil(metrics.schema)
        XCTAssertNil(metrics.generatedAt)
        XCTAssertNil(metrics.source)
        XCTAssertEqual(metrics.overall, .unknown)
        XCTAssertNil(metrics.statusLabel)
        XCTAssertTrue(metrics.components.isEmpty)
        XCTAssertEqual(metrics.activeIncidents, 0)
        XCTAssertNil(metrics.latency)
        XCTAssertNil(metrics.balance)
        XCTAssertNil(metrics.error)
        XCTAssertTrue(metrics.warnings.isEmpty)
        XCTAssertEqual(metrics.age(now: generatedAt), .infinity)
        XCTAssertEqual(metrics.freshness(now: generatedAt), .unavailable)
        XCTAssertEqual(metrics.displayStatus, "Unknown")
    }

    func testNullFieldsDecodeToDefaults() throws {
        let metrics = try decode(
            #"{"generated_at":null,"status":null,"latency":null,"balance":null,"error":null,"warnings":null,"source":null}"#
        )
        XCTAssertNil(metrics.generatedAt)
        XCTAssertEqual(metrics.overall, .unknown)
        XCTAssertNil(metrics.latency)
        XCTAssertNil(metrics.balance)
        XCTAssertNil(metrics.error)
        XCTAssertTrue(metrics.warnings.isEmpty)
    }

    func testMissingStatusDefaultsToUnknown() throws {
        let metrics = try decode(generatedAtJSON)
        XCTAssertEqual(metrics.overall, .unknown)
        XCTAssertEqual(metrics.generatedAt, generatedAt)
        XCTAssertTrue(metrics.components.isEmpty)
        XCTAssertEqual(metrics.activeIncidents, 0)
    }

    func testUnknownEnumValuesBecomeUnknown() throws {
        let metrics = try decode(
            #"{"status":{"overall":"meltdown","components":[{"id":"a","name":"API","status":"on fire"}]}}"#
        )
        XCTAssertEqual(metrics.overall, .unknown)
        XCTAssertEqual(metrics.components.first?.status, .unknown)

        XCTAssertEqual(metrics.displayStatus, "Unknown")
        XCTAssertEqual(
            try JSONDecoder().decode(MetricsStatus.self, from: Data(#""partial_outage""#.utf8)),
            .partialOutage
        )
        XCTAssertEqual(
            try JSONDecoder().decode(MetricsStatus.self, from: Data(#""full_outage""#.utf8)),
            .fullOutage
        )
        XCTAssertEqual(
            try JSONDecoder().decode(MetricsStatus.self, from: Data(#""nonsense""#.utf8)),
            .unknown
        )
    }

    func testMetricsStatusEncodesRawValue() throws {
        let data = try JSONEncoder().encode(MetricsStatus.partialOutage)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #""partial_outage""#)
    }

    func testNumbersAsStringsAreAccepted() throws {
        let metrics = try decode(
            #"""
            {"status":{"overall":"degraded","label":"Degraded performance","active_incidents":"2",
              "components":[{"id":"a","name":"API","status":"full_outage","uptime":"99.5"}]},
             "latency":{"ok":"true","ms":"214","p50_ms":"198.5","samples":"5"},
             "balance":{"available":"yes","currency":"USD","total":"12.34","top_up":"10","granted":2.34,"key_hint":"sk-abcd"}}
            """#
        )
        XCTAssertEqual(metrics.overall, .degraded)
        XCTAssertEqual(metrics.activeIncidents, 2)
        XCTAssertEqual(metrics.components.first?.status, .fullOutage)
        XCTAssertEqual(try XCTUnwrap(metrics.components.first?.uptime), 99.5, accuracy: 1e-12)
        XCTAssertEqual(metrics.latency?.ok, true)
        XCTAssertEqual(metrics.latency?.milliseconds, 214)
        XCTAssertEqual(metrics.latency?.p50Milliseconds, 198.5)
        XCTAssertEqual(metrics.latency?.samples, 5)
        XCTAssertEqual(metrics.balance?.available, true)
        let balance = try XCTUnwrap(metrics.balance)
        XCTAssertEqual(try XCTUnwrap(balance.total), 12.34, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(balance.topUp), 10, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(balance.granted), 2.34, accuracy: 1e-12)
    }

    func testMalformedNestedValuesAreIgnored() throws {
        let metrics = try decode(
            #"{"latency":"not an object","balance":[1,2],"status":{"components":[{"name":"Only name"},"garbage",{"id":"x"}]}}"#
        )
        XCTAssertNil(metrics.latency)
        XCTAssertNil(metrics.balance)
        XCTAssertEqual(metrics.components.count, 2)
        XCTAssertEqual(metrics.components[0].id, "Only name")
        XCTAssertEqual(metrics.components[0].name, "Only name")
        XCTAssertEqual(metrics.components[0].status, .unknown)
        XCTAssertEqual(metrics.components[1].id, "x")
        XCTAssertEqual(metrics.components[1].name, "x")
    }

    // MARK: - Timestamps and freshness

    func testTimestampsWithAndWithoutFractionalSeconds() throws {
        XCTAssertEqual(try decode(generatedAtJSON).generatedAt, generatedAt)

        let fractional = try decode(#"{"generated_at":"2026-10-30T09:12:00.500Z"}"#)
        XCTAssertEqual(
            fractional.generatedAt,
            generatedAt.addingTimeInterval(0.5)
        )

        let epoch = try decode(#"{"generated_at":1790000000}"#)
        XCTAssertEqual(epoch.generatedAt, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testAgeAndFreshnessPolicy() throws {
        let metrics = try decode(generatedAtJSON)
        XCTAssertEqual(metrics.age(now: generatedAt), 0, accuracy: 1e-9)
        XCTAssertEqual(metrics.age(now: generatedAt.addingTimeInterval(300)), 300, accuracy: 1e-9)

        XCTAssertEqual(metrics.freshness(now: generatedAt), .live)
        XCTAssertEqual(metrics.freshness(now: generatedAt.addingTimeInterval(119)), .live)
        XCTAssertEqual(metrics.freshness(now: generatedAt.addingTimeInterval(120)), .stale)
        XCTAssertEqual(metrics.freshness(now: generatedAt.addingTimeInterval(600)), .stale)
        XCTAssertEqual(metrics.freshness(now: generatedAt.addingTimeInterval(900)), .stale)
        XCTAssertEqual(metrics.freshness(now: generatedAt.addingTimeInterval(901)), .unavailable)
    }

    func testErrorField() throws {
        let metrics = try decode(#"{"error":"status fetch failed"}"#)
        XCTAssertEqual(metrics.error, "status fetch failed")
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try TrackerMetrics.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try TrackerMetrics.decode(Data()))
    }
}
