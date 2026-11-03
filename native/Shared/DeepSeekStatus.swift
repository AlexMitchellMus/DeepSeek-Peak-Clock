import Foundation

/// A parsed read of https://status.deepseek.com/ — the three main DeepSeek
/// services, plus the incident currently in progress (if any).
public enum DeepSeekStatus {
    /// One of the three services the widget shows.
    public struct Service: Sendable, Identifiable, Equatable {
        public let name: String       // full name from the page
        public let shortName: String  // "Pro", "Flash", "Chat"
        public let status: MetricsStatus
        public var id: String { shortName }
    }

    /// An incident as it is happening: status, start, and the affected services.
    public struct Event: Sendable, Equatable {
        public let title: String
        public let status: String        // investigating | identified | monitoring
        public let startedAt: Date?
        public let summary: String       // short English phrase, e.g. "fix applied, monitoring"
        public let affected: [String]    // short service names
    }

    public struct Reading: Sendable, Equatable {
        public var overall: MetricsStatus
        public var services: [Service]
        public var event: Event?
        public var componentCount: Int
    }

    public static let url = URL(string: "https://status.deepseek.com/")!

    /// Fetches and parses the page. Nil if it can't be read at all.
    public static func fetch(timeout: TimeInterval = 10) async -> Reading? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    // MARK: parsing

    /// Parses the page's embedded JSON payload. Exposed for tests and probes.
    public static func parse(_ html: String, now: Date = Date()) -> Reading? {
        let flat = html.replacingOccurrences(of: "\\\"", with: "\"")
        guard flat.contains("component_id") || flat.contains("active_changes") else { return nil }

        let components = componentNames(in: flat)
        let changes = activeChanges(in: flat)

        // Current status per component: from the incident's affected_components.
        var statusByComponent: [String: MetricsStatus] = [:]
        for change in changes {
            for affected in change.components {
                statusByComponent[normalizedName(affected.name)] = affected.status
            }
        }

        let services = primaryServices(from: components).map { component in
            Service(
                name: component,
                shortName: shortName(for: component),
                status: statusByComponent[normalizedName(component)] ?? .operational
            )
        }

        let event = changes.first.map { change in
            Event(
                title: englishText(change.title),
                status: change.status,
                startedAt: change.startedAt,
                summary: summary(for: change.status),
                affected: change.components.map { shortName(for: $0.name) }
            )
        }

        var overall = MetricsStatus.operational
        for service in services where service.status.severity > overall.severity {
            overall = service.status
        }
        if services.isEmpty { overall = .unknown }

        guard !components.isEmpty || !changes.isEmpty else { return nil }
        _ = now
        return Reading(overall: overall, services: services, event: event, componentCount: components.count)
    }

    // MARK: internals

    private struct ActiveChange {
        let title: String
        let status: String
        let startedAt: Date?
        let components: [(name: String, status: MetricsStatus)]
    }

    private static func activeChanges(in flat: String) -> [ActiveChange] {
        guard let arrayText = jsonValue(in: flat, after: "\"active_changes\":"),
              let data = arrayText.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { item -> ActiveChange? in
            guard let status = item["status"] as? String else { return nil }
            let components = (item["affected_components"] as? [[String: Any]] ?? []).compactMap { comp -> (String, MetricsStatus)? in
                guard let name = comp["name"] as? String else { return nil }
                return (name, MetricsStatus(status: comp["status"] as? String ?? ""))
            }
            let started = (item["start_at_seconds"] as? Double) ?? (item["start_at_seconds"] as? NSNumber)?.doubleValue
            return ActiveChange(
                title: item["title"] as? String ?? "Incident",
                status: status,
                startedAt: started.map { Date(timeIntervalSince1970: $0) },
                components: components
            )
        }
    }

    private static func componentNames(in flat: String) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        let pattern = "\"component_id\":\"([A-Z0-9]+)\",(?:\"section_id\":\"[A-Z0-9]*\",)?\"name\":\"([^\"]+)\""
        for row in matches(in: flat, pattern: pattern) where row.count > 1 {
            guard !seen.contains(row[0]) else { continue }
            seen.insert(row[0])
            names.append(row[1])
            if names.count == 8 { break }
        }
        return names
    }

    /// The three DeepSeek services the widget reports on, in display order.
    private static func primaryServices(from components: [String]) -> [String] {
        let wanted = ["v4 pro", "v4.1 flash", "chat"]
        var picked: [String] = []
        for key in wanted {
            if let match = components.first(where: { $0.lowercased().contains(key) }) {
                picked.append(match)
            }
        }
        if picked.count < 3 {
            // Fall back to the API services in page order.
            for name in components where !picked.contains(name) && picked.count < 3 {
                picked.append(name)
            }
        }
        return picked
    }

    /// English-only, bracket-free key used to match names across the two encodings
    /// the page uses (raw `\uXXXX` escapes vs decoded characters).
    private static func normalizedName(_ name: String) -> String {
        var out = name.replacingOccurrences(of: "[（(][^)）]*[)）]", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\\\u[0-9a-fA-F]{4}", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// `"DeepSeek V4.1 Flash API服务(API Service)"` → `"Flash"`.
    private static func shortName(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("flash") { return "Flash" }
        if lower.contains("pro") { return "Pro" }
        if lower.contains("chat") || name.contains("对话") { return "Chat" }
        let ascii = name.replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "", options: .regularExpression)
        let first = ascii.split(separator: " ").first.map(String.init) ?? "API"
        return first
    }

    /// Short human phrase for an incident state.
    private static func summary(for status: String) -> String {
        switch status {
        case "investigating": return "investigating"
        case "identified": return "fix identified"
        case "monitoring": return "fix applied, monitoring"
        case "resolved": return "resolved"
        default: return status.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Drops the Chinese half of the page's bilingual strings.
    private static func englishText(_ text: String) -> String {
        let parts = text.components(separatedBy: "\n").filter { line in
            line.range(of: "[A-Za-z]", options: .regularExpression) != nil
        }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? text : joined
    }

    // MARK: JSON slicing

    /// Finds `key` then returns the balanced JSON `[`/`{` value that follows it.
    static func jsonValue(in text: String, after key: String) -> String? {
        guard let keyRange = text.range(of: key) else { return nil }
        var index = keyRange.upperBound
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        guard index < text.endIndex, text[index] == "[" || text[index] == "{" else { return nil }
        let open = text[index]
        let close: Character = open == "[" ? "]" : "}"

        var depth = 0
        var inString = false
        var escaped = false
        var cursor = index
        while cursor < text.endIndex {
            let char = text[cursor]
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
            } else if char == open {
                depth += 1
            } else if char == close {
                depth -= 1
                if depth == 0 { return String(text[index...cursor]) }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func matches(in string: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).map { match in
            (1..<match.numberOfRanges).map { index in
                guard let r = Range(match.range(at: index), in: string) else { return "" }
                return String(string[r])
            }
        }
    }
}

extension MetricsStatus {
    /// Lenient mapping from the status page's snake_case values.
    init(status: String) {
        switch status {
        case "operational": self = .operational
        case "degraded": self = .degraded
        case "partial_outage": self = .partialOutage
        case "full_outage": self = .fullOutage
        case "maintenance": self = .maintenance
        default: self = .unknown
        }
    }
}

/// Measures DeepSeek API reachability/latency without an API key.
public enum DeepSeekLatency {
    public static let url = URL(string: "https://api.deepseek.com/models")!

    /// Runs `samples` sequential probes; a 401 counts as reachable.
    public static func measure(samples: Int = 3, timeout: TimeInterval = 4) async -> LatencyMetrics {
        var durations: [Double] = []
        var anyOK = false
        for _ in 0..<max(1, samples) {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let started = Date()
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse {
                anyOK = true
                durations.append(Date().timeIntervalSince(started) * 1000)
                _ = http.statusCode
            }
        }
        durations.sort()
        let p50 = durations.isEmpty ? nil : durations[durations.count / 2]
        return LatencyMetrics(
            ok: anyOK,
            milliseconds: durations.last.map { ($0 * 10).rounded() / 10 },
            p50Milliseconds: p50.map { ($0 * 10).rounded() / 10 },
            samples: durations.count,
            endpoint: "api.deepseek.com",
            checkedAt: Date()
        )
    }
}
