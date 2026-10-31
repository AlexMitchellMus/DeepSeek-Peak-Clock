import Foundation

/// The public status page, parsed directly (no collector, no API key).
///
/// `status.deepseek.com` is a server-rendered status page; the component list and the
/// incident windows live in an escaped JSON payload inside the page. This reads just
/// enough of it to answer "is the API OK right now".
public enum DeepSeekStatus {
    /// Parsed view of the status page.
    public struct Reading: Sendable {
        public var overall: MetricsStatus
        public var componentNames: [String]
        public var activeIncidents: Int
    }

    public static let url = URL(string: "https://status.deepseek.com/")!

    /// Fetches and parses the status page. Returns nil if it cannot be read.
    public static func fetch(timeout: TimeInterval = 10) async -> Reading? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Parses the page's flight payload. Exposed for tests.
    public static func parse(_ html: String, now: Date = Date()) -> Reading? {
        // The payload is a JS string, so quotes arrive escaped.
        let flat = html.replacingOccurrences(of: "\\\"", with: "\"")
        guard flat.contains("component_id") else { return nil }

        // The component list is repeated several times in the payload; keep the first
        // occurrence of each id, in page order.
        var seen = Set<String>()
        var names: [String] = []
        for row in matches(in: flat, pattern: "\"component_id\":\"([A-Z0-9]+)\",(?:\"section_id\":\"[A-Z0-9]*\",)?\"name\":\"([^\"]+)\"") {
            guard row.count > 1, !seen.contains(row[0]) else { continue }
            seen.insert(row[0])
            let name = cleanName(row[1])
            if !name.isEmpty { names.append(name) }
            if names.count == 8 { break }
        }

        let incidents = matches(
            in: flat,
            pattern: "\"change_id\":(\\d+),\"start_at_seconds\":(\\d+),\"end_at_seconds\":(\\d+),\"status\":\"([a-z_]+)\""
        )

        let epoch = now.timeIntervalSince1970
        var activeIDs = Set<String>()
        var overall = MetricsStatus.operational
        var rank = 0
        for row in incidents where row.count >= 4 {
            guard let end = Double(row[2]), end > epoch else { continue }
            activeIDs.insert(row[0])
            let status = MetricsStatus(status: row[3])
            let severity = status.severity
            if severity > rank {
                rank = severity
                overall = status
            }
        }
        if incidents.isEmpty, overall == .operational {
            // No incident data at all is not evidence of health.
            return nil
        }
        return Reading(overall: overall, componentNames: names, activeIncidents: activeIDs.count)
    }

    // MARK: helpers

    /// `"DeepSeek V4 Pro API服务(API Service)"` → `"DeepSeek V4 Pro API"`,
    /// `"对话服务(Chatservice)"` → `"Chatservice"`.
    private static func cleanName(_ raw: String) -> String {
        let inner = matches(in: raw, pattern: "[（(]([^)）]+)[)）]").first?.first ?? ""
        var outer = raw.replacingOccurrences(of: "[（(][^)）]*[)）]", with: "", options: .regularExpression)
        outer = outer.replacingOccurrences(of: "[\u{4E00}-\u{9FFF}]+", with: "", options: .regularExpression)
        outer = outer.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        outer = outer.trimmingCharacters(in: .whitespaces)
        return outer.count >= 4 ? outer : (inner.isEmpty ? outer : inner)
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
                if http.statusCode >= 500 { /* still reachable */ }
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
