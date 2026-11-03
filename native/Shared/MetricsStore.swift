import Foundation
import Combine

/// Loads metrics: the local collector first (richer: uptime, balance), then
/// DeepSeek's own status page + latency probe directly (no setup required).
public enum MetricsFetcher {
    /// `DEEPSEEK_TRACKER_METRICS_URL` if set, else the collector's default endpoint.
    public static func resolvedURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["DEEPSEEK_TRACKER_METRICS_URL"],
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://127.0.0.1:8787/metrics.json")!
    }

    /// Collector first, direct measurement as the fallback. Never throws.
    public static func fetch(from url: URL) async -> MetricsSnapshot {
        if let snapshot = await fetchCollector(from: url) {
            return snapshot
        }
        return await fetchDirect()
    }

    /// Reads the collector's `metrics.json`. Nil when nothing answers there.
    static func fetchCollector(from url: URL) async -> MetricsSnapshot? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(http.statusCode) else { return nil }
        guard let metrics = try? TrackerMetrics.decode(data) else { return nil }
        MetricsCache.save(metrics)
        return MetricsSnapshot(metrics: metrics, freshness: metrics.freshness(now: Date()), detail: nil)
    }

    /// Widget-timeline friendly fetch: returns within `deadline` seconds, falling back
    /// to the last good payload (or an offline card) so the timeline always completes.
    public static func fetchForTimeline(deadline: TimeInterval = 5) async -> MetricsSnapshot {
        let url = resolvedURL()
        let snapshot = await withTaskGroup(of: MetricsSnapshot?.self) { group -> MetricsSnapshot? in
            group.addTask { await fetch(from: url) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let snapshot { return snapshot }
        if let cached = MetricsCache.load() { return cached }
        return MetricsSnapshot(freshness: .unavailable, detail: "DeepSeek unreachable")
    }

    /// Asks DeepSeek's status page for component health and times the API directly.
    public static func fetchDirect() async -> MetricsSnapshot {
        async let statusTask = DeepSeekStatus.fetch()
        async let latencyTask = DeepSeekLatency.measure()
        let (reading, latency) = await (statusTask, latencyTask)

        guard reading != nil || (latency.ok && (latency.samples ?? 0) > 0) else {
            return MetricsSnapshot(freshness: .unavailable, detail: "DeepSeek unreachable")
        }

        let components = (reading?.services ?? []).map {
            ComponentMetrics(id: $0.shortName, name: $0.name, status: $0.status)
        }
        let metrics = TrackerMetrics(
            schema: 1,
            generatedAt: Date(),
            source: "status.deepseek.com",
            overall: reading?.overall ?? .unknown,
            statusLabel: nil,
            components: components,
            activeIncidents: reading?.event == nil ? 0 : 1,
            latency: latency,
            balance: nil
        )
        MetricsCache.save(metrics)
        return MetricsSnapshot(
            metrics: metrics,
            freshness: .live,
            detail: nil,
            services: reading?.services ?? [],
            event: reading?.event
        )
    }
}

/// Last good payload, cached in the extension's own defaults so a slow network
/// never leaves the widget in its placeholder state.
private enum MetricsCache {
    static let key = "ds.lastGoodMetrics"
    static let maxAge: TimeInterval = 6 * 60 * 60

    static func save(_ metrics: TrackerMetrics) {
        guard let data = try? JSONEncoder().encode(metrics) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load(now: Date = Date()) -> MetricsSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let metrics = try? TrackerMetrics.decode(data) else { return nil }
        let age = metrics.generatedAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard age < maxAge else { return nil }
        return MetricsSnapshot(metrics: metrics, freshness: .stale, detail: nil)
    }
}

/// Observable wrapper used by the app window; the widget fetches directly.
@MainActor
public final class MetricsStore: ObservableObject {
    /// Latest reading handed to the card.
    @Published public private(set) var snapshot: MetricsSnapshot = .loading
    /// Collector endpoint attempted first.
    @Published public private(set) var url: URL
    /// Last refresh timestamp.
    @Published public private(set) var refreshedAt: Date?

    public init(url: URL = MetricsFetcher.resolvedURL()) {
        self.url = url
    }

    /// One refresh cycle.
    public func refresh() async {
        snapshot = await MetricsFetcher.fetch(from: url)
        refreshedAt = Date()
    }

    /// Refresh immediately, then every `interval` seconds until cancelled.
    public func refreshLoop(every interval: TimeInterval = 60) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}
