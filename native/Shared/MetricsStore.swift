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
        return MetricsSnapshot(metrics: metrics, freshness: metrics.freshness(now: Date()), detail: nil)
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
        return MetricsSnapshot(
            metrics: metrics,
            freshness: .live,
            detail: nil,
            services: reading?.services ?? [],
            event: reading?.event
        )
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
