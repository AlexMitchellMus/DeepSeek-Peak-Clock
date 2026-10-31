import Foundation

/// DeepSeek's rate card (SPEC.md §3), in USD per 1M tokens.
public enum PriceTable {
    /// One published rate, with its off-peak and peak values in USD per 1M tokens.
    public struct Price: Sendable, Equatable {
        /// Off-peak price in USD per 1M tokens.
        public let off: Double
        /// Peak price in USD per 1M tokens; always twice the off-peak price.
        public let peak: Double

        /// Creates a price pair from its off-peak value; peak is twice off-peak.
        public init(off: Double) {
            self.off = off
            self.peak = off * 2
        }

        /// The price for a kind.
        public func value(for kind: PriceKind) -> Double {
            kind == .peak ? peak : off
        }

        /// The formatted price for a kind, e.g. `"$0.30"`.
        public func formatted(for kind: PriceKind) -> String {
            PriceTable.formatted(value(for: kind))
        }
    }

    /// The token buckets of a rate card.
    public enum Bucket: String, Sendable, CaseIterable {
        /// Prompt input tokens.
        case input
        /// Cached (repeated prefix) input tokens.
        case cachedInput = "cached input"
        /// Generated output tokens.
        case output
    }

    /// One model's rate card row.
    public struct Row: Sendable, Identifiable {
        /// Display name, e.g. `"DeepSeek V4.1 Flash"`.
        public let model: String
        /// Input-token price.
        public let input: Price
        /// Cached-input-token price.
        public let cachedInput: Price
        /// Output-token price.
        public let output: Price

        /// Stable SwiftUI identity: the model name.
        public var id: String { model }

        /// Creates a rate card row.
        public init(model: String, input: Price, cachedInput: Price, output: Price) {
            self.model = model
            self.input = input
            self.cachedInput = cachedInput
            self.output = output
        }

        /// The price for a bucket.
        public func price(_ bucket: Bucket) -> Price {
            switch bucket {
            case .input: return input
            case .cachedInput: return cachedInput
            case .output: return output
            }
        }

        /// The formatted price for a bucket at a kind, e.g. `"$0.15"`.
        public func formatted(_ bucket: Bucket, kind: PriceKind) -> String {
            price(bucket).formatted(for: kind)
        }
    }

    /// Rate cards, Flash first. Peak values follow automatically (2x off-peak).
    public static let rows: [Row] = [
        Row(
            model: "DeepSeek V4.1 Flash",
            input: Price(off: 0.15),
            cachedInput: Price(off: 0.003),
            output: Price(off: 0.60)
        ),
        Row(
            model: "DeepSeek V4 Pro",
            input: Price(off: 0.66),
            cachedInput: Price(off: 0.022),
            output: Price(off: 1.98)
        )
    ]

    /// Formats a USD rate with two or three decimals: `"$0.15"`, `"$1.20"`, `"$0.003"`, `"$3.96"`.
    public static func formatted(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        if text.hasSuffix("0") { text.removeLast() }
        return "$" + text
    }

    /// The row for a model name, when the name matches a rate card.
    public static func row(for model: String) -> Row? {
        rows.first { $0.model == model }
    }

    /// Web search / fetch price in USD per 1K requests (footnote, not a rate card).
    public static let webSearchPerThousandRequests: Double = 0.75

    /// Footnote text for the web search / fetch price.
    public static let webSearchFootnote: String = "Web search / fetch: $0.75 per 1K requests"
}
