import Foundation
import XCTest
@testable import DeepSeekCore

final class PricingTests: XCTestCase {
    func testRateCardMatchesSpec() {
        XCTAssertEqual(PriceTable.rows.map(\.model), ["DeepSeek V4.1 Flash", "DeepSeek V4 Pro"])
        XCTAssertEqual(PriceTable.rows.count, 2)

        let flash = PriceTable.rows[0]
        XCTAssertEqual(flash.input.off, 0.15, accuracy: 1e-12)
        XCTAssertEqual(flash.input.peak, 0.30, accuracy: 1e-12)
        XCTAssertEqual(flash.cachedInput.off, 0.003, accuracy: 1e-12)
        XCTAssertEqual(flash.cachedInput.peak, 0.006, accuracy: 1e-12)
        XCTAssertEqual(flash.output.off, 0.60, accuracy: 1e-12)
        XCTAssertEqual(flash.output.peak, 1.20, accuracy: 1e-12)

        let pro = PriceTable.rows[1]
        XCTAssertEqual(pro.input.off, 0.66, accuracy: 1e-12)
        XCTAssertEqual(pro.input.peak, 1.32, accuracy: 1e-12)
        XCTAssertEqual(pro.cachedInput.off, 0.022, accuracy: 1e-12)
        XCTAssertEqual(pro.cachedInput.peak, 0.044, accuracy: 1e-12)
        XCTAssertEqual(pro.output.off, 1.98, accuracy: 1e-12)
        XCTAssertEqual(pro.output.peak, 3.96, accuracy: 1e-12)
    }

    func testPeakIsAlwaysTwiceOffPeak() {
        for row in PriceTable.rows {
            for bucket in PriceTable.Bucket.allCases {
                let price = row.price(bucket)
                XCTAssertEqual(
                    price.peak,
                    price.off * 2,
                    accuracy: 1e-12,
                    "\(row.model) \(bucket.rawValue): peak must be 2x off-peak"
                )
            }
        }
    }

    func testFormattedValues() {
        XCTAssertEqual(PriceTable.formatted(0.15), "$0.15")
        XCTAssertEqual(PriceTable.formatted(0.30), "$0.30")
        XCTAssertEqual(PriceTable.formatted(0.003), "$0.003")
        XCTAssertEqual(PriceTable.formatted(0.006), "$0.006")
        XCTAssertEqual(PriceTable.formatted(0.022), "$0.022")
        XCTAssertEqual(PriceTable.formatted(0.044), "$0.044")
        XCTAssertEqual(PriceTable.formatted(0.60), "$0.60")
        XCTAssertEqual(PriceTable.formatted(1.20), "$1.20")
        XCTAssertEqual(PriceTable.formatted(3.96), "$3.96")
        XCTAssertEqual(PriceTable.formatted(2.0), "$2.00")
        XCTAssertEqual(PriceTable.formatted(0.0), "$0.00")
    }

    func testRowFormattingByBucketAndKind() {
        let flash = PriceTable.rows[0]
        XCTAssertEqual(flash.formatted(.input, kind: .off), "$0.15")
        XCTAssertEqual(flash.formatted(.input, kind: .peak), "$0.30")
        XCTAssertEqual(flash.formatted(.cachedInput, kind: .off), "$0.003")
        XCTAssertEqual(flash.formatted(.cachedInput, kind: .peak), "$0.006")
        XCTAssertEqual(flash.formatted(.output, kind: .peak), "$1.20")

        let pro = PriceTable.rows[1]
        XCTAssertEqual(pro.formatted(.cachedInput, kind: .off), "$0.022")
        XCTAssertEqual(pro.formatted(.output, kind: .peak), "$3.96")
        XCTAssertEqual(pro.price(.output).value(for: .off), 1.98, accuracy: 1e-12)
    }

    func testRowLookupAndFootnote() throws {
        XCTAssertEqual(
            try XCTUnwrap(PriceTable.row(for: "DeepSeek V4 Pro")).output.peak,
            3.96,
            accuracy: 1e-12
        )
        XCTAssertNil(PriceTable.row(for: "DeepSeek V3"))
        XCTAssertEqual(PriceTable.webSearchPerThousandRequests, 0.75, accuracy: 1e-12)
        XCTAssertEqual(PriceTable.webSearchFootnote, "Web search / fetch: $0.75 per 1K requests")
    }
}
