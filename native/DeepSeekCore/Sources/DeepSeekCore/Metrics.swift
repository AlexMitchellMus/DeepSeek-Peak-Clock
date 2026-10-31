import Foundation

/// Freshness bucket for a metrics payload (SPEC.md §4 age policy).
public enum Freshness: String, Codable, Sendable, CaseIterable {
    /// No payload has been loaded yet; supplied by the caller, never by `age(now:)`.
    case loading
    /// Younger than two minutes.
    case live
    /// Two to fifteen minutes old; render dimmed with the age.
    case stale
    /// Older than fifteen minutes, or the payload has no timestamp.
    case unavailable
}

/// Overall health of the DeepSeek API surface.
public enum MetricsStatus: String, Codable, Sendable, CaseIterable {
    /// All systems operational.
    case operational
    /// Degraded performance.
    case degraded
    /// Some components are down; the raw value is `partial_outage`.
    case partialOutage = "partial_outage"
    /// A full outage; the raw value is `full_outage`.
    case fullOutage = "full_outage"
    /// Planned maintenance.
    case maintenance
    /// Missing or unrecognised status.
    case unknown

    /// Decodes any status string, falling back to `.unknown` for unrecognised values.
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = MetricsStatus(rawValue: key) ?? .unknown
    }

    /// Encodes the canonical raw value.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Short title suitable for a status pill, e.g. `"Partial outage"`.
    public var displayName: String {
        switch self {
        case .operational: return "Operational"
        case .degraded: return "Degraded"
        case .partialOutage: return "Partial outage"
        case .fullOutage: return "Full outage"
        case .maintenance: return "Maintenance"
        case .unknown: return "Unknown"
        }
    }

    /// Severity rank, where a higher value is worse; useful for picking a worst component.
    public var severity: Int {
        switch self {
        case .operational: return 0
        case .maintenance: return 1
        case .degraded: return 2
        case .partialOutage: return 3
        case .fullOutage: return 4
        case .unknown: return 5
        }
    }
}

/// One status-page component entry.
public struct ComponentMetrics: Codable, Sendable, Identifiable {
    /// Stable component id; falls back to the name when the source omits it.
    public var id: String
    /// Human-readable component name.
    public var name: String
    /// Component status; `.unknown` when missing or unrecognised.
    public var status: MetricsStatus
    /// 90-day uptime percentage, when reported.
    public var uptime: Double?

    /// Creates a component entry.
    public init(id: String, name: String, status: MetricsStatus = .unknown, uptime: Double? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.uptime = uptime
    }

    /// Decodes a component leniently, tolerating missing ids, names and statuses.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = container.lenientString(.id)
        let rawName = container.lenientString(.name)
        let name = rawName ?? rawID ?? "Component"
        self.id = rawID ?? name
        self.name = name
        self.status = ((try? container.decodeIfPresent(MetricsStatus.self, forKey: .status)) ?? nil) ?? .unknown
        self.uptime = container.lenientDouble(.uptime)
    }
}

/// The collector's local latency probe result.
public struct LatencyMetrics: Codable, Sendable {
    /// Whether the probe succeeded.
    public var ok: Bool
    /// Probe latency in milliseconds; JSON key `ms`.
    public var milliseconds: Double?
    /// Median latency in milliseconds; JSON key `p50_ms`.
    public var p50Milliseconds: Double?
    /// Number of probe samples.
    public var samples: Int?
    /// Probed endpoint, e.g. `"api.deepseek.com"`.
    public var endpoint: String?
    /// When the probe ran.
    public var checkedAt: Date?

    /// Creates a latency result.
    public init(
        ok: Bool = false,
        milliseconds: Double? = nil,
        p50Milliseconds: Double? = nil,
        samples: Int? = nil,
        endpoint: String? = nil,
        checkedAt: Date? = nil
    ) {
        self.ok = ok
        self.milliseconds = milliseconds
        self.p50Milliseconds = p50Milliseconds
        self.samples = samples
        self.endpoint = endpoint
        self.checkedAt = checkedAt
    }

    /// Decodes a probe result leniently, tolerating nulls and numeric strings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ok = container.lenientBool(.ok) ?? false
        self.milliseconds = container.lenientDouble(.milliseconds)
        self.p50Milliseconds = container.lenientDouble(.p50Milliseconds)
        self.samples = container.lenientInt(.samples)
        self.endpoint = container.lenientString(.endpoint)
        self.checkedAt = container.lenientDate(.checkedAt)
    }

    /// Encodes the probe result using the `metrics.json` field names.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encodeIfPresent(milliseconds, forKey: .milliseconds)
        try container.encodeIfPresent(p50Milliseconds, forKey: .p50Milliseconds)
        try container.encodeIfPresent(samples, forKey: .samples)
        try container.encodeIfPresent(endpoint, forKey: .endpoint)
        if let checkedAt {
            try container.encode(LenientDate.string(from: checkedAt), forKey: .checkedAt)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case milliseconds = "ms"
        case p50Milliseconds = "p50_ms"
        case samples
        case endpoint
        case checkedAt = "checked_at"
    }
}

/// Optional DeepSeek account balance, present only when the collector had an API key.
public struct BalanceMetrics: Codable, Sendable {
    /// Whether a balance was actually retrieved.
    public var available: Bool
    /// Currency code, e.g. `"USD"`.
    public var currency: String?
    /// Total available balance.
    public var total: Double?
    /// Portion that came from top-ups.
    public var topUp: Double?
    /// Portion that came from grants.
    public var granted: Double?
    /// Masked API-key hint, e.g. `"sk-…abcd"`.
    public var keyHint: String?

    /// Creates a balance result.
    public init(
        available: Bool = false,
        currency: String? = nil,
        total: Double? = nil,
        topUp: Double? = nil,
        granted: Double? = nil,
        keyHint: String? = nil
    ) {
        self.available = available
        self.currency = currency
        self.total = total
        self.topUp = topUp
        self.granted = granted
        self.keyHint = keyHint
    }

    /// Decodes a balance leniently, tolerating nulls and numeric strings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.available = container.lenientBool(.available) ?? false
        self.currency = container.lenientString(.currency)
        self.total = container.lenientDouble(.total)
        self.topUp = container.lenientDouble(.topUp)
        self.granted = container.lenientDouble(.granted)
        self.keyHint = container.lenientString(.keyHint)
    }

    private enum CodingKeys: String, CodingKey {
        case available
        case currency
        case total
        case topUp = "top_up"
        case granted
        case keyHint = "key_hint"
    }
}

/// The whole `metrics/metrics.json` payload (schema v1), decoded leniently.
///
/// Missing files, partial files, null fields, unknown status strings and numeric strings
/// all decode successfully; the app then renders `unavailable`/`stale` instead of failing.
public struct TrackerMetrics: Codable, Sendable {
    /// Raw schema version, when present.
    public var schema: Int?
    /// When the collector generated the payload.
    public var generatedAt: Date?
    /// Upstream source identifier, e.g. `"status.deepseek.com"`.
    public var source: String?
    /// Overall API status; `.unknown` when missing or unrecognised.
    public var overall: MetricsStatus
    /// Short human status label from the source.
    public var statusLabel: String?
    /// Component statuses, ordered by importance (at most six by contract).
    public var components: [ComponentMetrics]
    /// Number of active incidents.
    public var activeIncidents: Int
    /// Local latency probe result.
    public var latency: LatencyMetrics?
    /// Optional account balance.
    public var balance: BalanceMetrics?
    /// Error string when a data source failed.
    public var error: String?
    /// Non-fatal collector warnings.
    public var warnings: [String]

    /// Creates a metrics payload, defaulting to the "nothing loaded yet" state.
    public init(
        schema: Int? = nil,
        generatedAt: Date? = nil,
        source: String? = nil,
        overall: MetricsStatus = .unknown,
        statusLabel: String? = nil,
        components: [ComponentMetrics] = [],
        activeIncidents: Int = 0,
        latency: LatencyMetrics? = nil,
        balance: BalanceMetrics? = nil,
        error: String? = nil,
        warnings: [String] = []
    ) {
        self.schema = schema
        self.generatedAt = generatedAt
        self.source = source
        self.overall = overall
        self.statusLabel = statusLabel
        self.components = components
        self.activeIncidents = activeIncidents
        self.latency = latency
        self.balance = balance
        self.error = error
        self.warnings = warnings
    }

    /// Age of the payload in seconds; `.infinity` when it carries no timestamp.
    public func age(now: Date) -> TimeInterval {
        guard let generatedAt else { return .infinity }
        return now.timeIntervalSince(generatedAt)
    }

    /// Freshness per SPEC.md §4: live under 2 min, stale up to 15 min, otherwise unavailable.
    public func freshness(now: Date) -> Freshness {
        guard generatedAt != nil else { return .unavailable }
        let age = age(now: now)
        if age < 120 { return .live }
        if age <= 900 { return .stale }
        return .unavailable
    }

    /// The status title to render when the source supplied no label.
    public var displayStatus: String {
        statusLabel ?? overall.displayName
    }

    /// Decodes a raw `metrics.json` payload leniently.
    public static func decode(_ data: Data) throws -> TrackerMetrics {
        try JSONDecoder().decode(TrackerMetrics.self, from: data)
    }

    /// Decodes the payload field by field, ignoring anything malformed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = container.lenientInt(.schema)
        self.generatedAt = container.lenientDate(.generatedAt)
        self.source = container.lenientString(.source)
        self.error = container.lenientString(.error)
        self.warnings = container.lenientStringArray(.warnings)

        var overall: MetricsStatus = .unknown
        var label: String?
        var components: [ComponentMetrics] = []
        var activeIncidents = 0
        if let status = try? container.nestedContainer(keyedBy: StatusKeys.self, forKey: .status) {
            overall = ((try? status.decodeIfPresent(MetricsStatus.self, forKey: .overall)) ?? nil) ?? .unknown
            label = status.lenientString(.label)
            components = status.lenientArray(ComponentMetrics.self, .components)
            activeIncidents = status.lenientInt(.activeIncidents) ?? 0
        }
        self.overall = overall
        self.statusLabel = label
        self.components = components
        self.activeIncidents = activeIncidents
        self.latency = ((try? container.decodeIfPresent(LatencyMetrics.self, forKey: .latency)) ?? nil)
        self.balance = ((try? container.decodeIfPresent(BalanceMetrics.self, forKey: .balance)) ?? nil)
    }

    /// Encodes the payload using the `metrics.json` field names.
    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: CodingKeys.self)
        try root.encodeIfPresent(schema, forKey: .schema)
        if let generatedAt {
            try root.encode(LenientDate.string(from: generatedAt), forKey: .generatedAt)
        }
        try root.encodeIfPresent(source, forKey: .source)
        var status = root.nestedContainer(keyedBy: StatusKeys.self, forKey: .status)
        try status.encode(overall, forKey: .overall)
        try status.encodeIfPresent(statusLabel, forKey: .label)
        try status.encode(components, forKey: .components)
        try status.encode(activeIncidents, forKey: .activeIncidents)
        try root.encodeIfPresent(latency, forKey: .latency)
        try root.encodeIfPresent(balance, forKey: .balance)
        try root.encodeIfPresent(error, forKey: .error)
        if !warnings.isEmpty {
            try root.encode(warnings, forKey: .warnings)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case source
        case status
        case latency
        case balance
        case error
        case warnings
    }

    private enum StatusKeys: String, CodingKey {
        case overall
        case label
        case components
        case activeIncidents = "active_incidents"
    }
}

// MARK: - Lenient decoding helpers

/// Decodes one element without failing the surrounding array.
private struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// ISO-8601 parsing and formatting shared by the metrics types.
private enum LenientDate {
    static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }

        if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}

private extension KeyedDecodingContainer {
    /// A non-empty trimmed string, or `nil` for missing/null/empty values.
    func lenientString(_ key: Key) -> String? {
        guard let text = (try? decodeIfPresent(String.self, forKey: key)) ?? nil else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A double from a JSON number or a numeric string.
    func lenientDouble(_ key: Key) -> Double? {
        if let number = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil { return number }
        if let text = (try? decodeIfPresent(String.self, forKey: key)) ?? nil {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// An int from a JSON number or a numeric string.
    func lenientInt(_ key: Key) -> Int? {
        if let number = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil { return Int(number) }
        if let text = (try? decodeIfPresent(String.self, forKey: key)) ?? nil {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(trimmed) { return value }
            if let value = Double(trimmed) { return Int(value) }
        }
        return nil
    }

    /// A bool from a JSON bool, a `"true"`/`"false"`-style string, or a 0/1 number.
    func lenientBool(_ key: Key) -> Bool? {
        if let value = (try? decodeIfPresent(Bool.self, forKey: key)) ?? nil { return value }
        if let text = (try? decodeIfPresent(String.self, forKey: key)) ?? nil {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        if let number = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil { return number != 0 }
        return nil
    }

    /// A date from an ISO-8601 string (with or without fractional seconds) or epoch seconds.
    func lenientDate(_ key: Key) -> Date? {
        if let text = (try? decodeIfPresent(String.self, forKey: key)) ?? nil {
            return LenientDate.parse(text)
        }
        if let number = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil {
            return Date(timeIntervalSince1970: number)
        }
        return nil
    }

    /// An array of strings; malformed elements and non-arrays become `[]`.
    func lenientStringArray(_ key: Key) -> [String] {
        guard let values = (try? decodeIfPresent([String].self, forKey: key)) ?? nil else { return [] }
        return values
    }

    /// An array of values, silently dropping elements that fail to decode.
    func lenientArray<Value: Decodable>(_ type: Value.Type, _ key: Key) -> [Value] {
        guard let values = (try? decodeIfPresent([FailableDecodable<Value>].self, forKey: key)) ?? nil
        else { return [] }
        return values.compactMap(\.value)
    }
}
