import SwiftUI
import WidgetKit

// MARK: - Timeline

struct TrackerEntry: TimelineEntry {
    let date: Date
    let metrics: MetricsSnapshot
}

struct TrackerProvider: TimelineProvider {
    func placeholder(in context: Context) -> TrackerEntry {
        TrackerEntry(date: Date(), metrics: .loading)
    }

    func getSnapshot(in context: Context, completion: @escaping (TrackerEntry) -> Void) {
        if context.isPreview {
            completion(TrackerEntry(date: Date(), metrics: .unavailable))
            return
        }
        Task {
            let metrics = await MetricsFetcher.fetch(from: MetricsFetcher.resolvedURL())
            completion(TrackerEntry(date: Date(), metrics: metrics))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrackerEntry>) -> Void) {
        Task {
            let now = Date()
            let metrics = await MetricsFetcher.fetch(from: MetricsFetcher.resolvedURL())
            let entry = TrackerEntry(date: now, metrics: metrics)

            // Refresh exactly when the price flips, and at least every 15 minutes
            // so the metrics row stays reasonably fresh.
            let switchDate = PeakClock.nextSwitches(after: now, count: 1).first?.date
                ?? now.addingTimeInterval(900)
            let refresh = min(switchDate.addingTimeInterval(5), now.addingTimeInterval(900))
            completion(Timeline(entries: [entry], policy: .after(refresh)))
        }
    }
}

// MARK: - View

struct TrackerWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: TrackerEntry

    private var size: WidgetSize {
        switch family {
        case .systemSmall: return .small
        case .systemLarge, .systemExtraLarge: return .large
        default: return .medium
        }
    }

    var body: some View {
        TrackerCard(
            snapshot: TrackerSnapshot(now: entry.date),
            metrics: entry.metrics,
            mode: colorScheme == .dark ? .dark : .light,
            size: size,
            zoneOffsetMinutes: DisplayZone.offsetMinutes(for: entry.date),
            showsZone: size != .small,
            liveCountdown: true,
            fillsAvailableSpace: true
        )
        .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Widget

struct DeepSeekTrackerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DeepSeekTrackerWidget", provider: TrackerProvider()) { entry in
            TrackerWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("DeepSeek Peak Clock")
        .description("How long until DeepSeek's next off-peak half-price window.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct DeepSeekTrackerWidgetBundle: WidgetBundle {
    var body: some Widget {
        DeepSeekTrackerWidget()
    }
}
