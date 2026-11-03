import SwiftUI
import WidgetKit
import AppIntents

// MARK: - Configuration

/// Per-widget option shown in the widget gallery ("Edit Widget").
public struct TrackerWidgetConfiguration: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "DeepSeek Tracker"
    public static var description = IntentDescription("Choose whether to show the rolling next 24 hours as well.")

    @Parameter(title: "Show next 24 hours", default: false)
    public var showNextDayBar: Bool

    public init() {}
}

// MARK: - Timeline

struct TrackerEntry: TimelineEntry {
    let date: Date
    let metrics: MetricsSnapshot
    let showsNextDayBar: Bool
}

struct TrackerProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TrackerEntry {
        TrackerEntry(date: Date(), metrics: .loading, showsNextDayBar: false)
    }

    func snapshot(for configuration: TrackerWidgetConfiguration, in context: Context) async -> TrackerEntry {
        if context.isPreview {
            return TrackerEntry(date: Date(), metrics: .unavailable, showsNextDayBar: configuration.showNextDayBar)
        }
        let metrics = await MetricsFetcher.fetch(from: MetricsFetcher.resolvedURL())
        return TrackerEntry(date: Date(), metrics: metrics, showsNextDayBar: configuration.showNextDayBar)
    }

    func timeline(for configuration: TrackerWidgetConfiguration, in context: Context) async -> Timeline<TrackerEntry> {
        let now = Date()
        let metrics = await MetricsFetcher.fetch(from: MetricsFetcher.resolvedURL())
        let entry = TrackerEntry(date: now, metrics: metrics, showsNextDayBar: configuration.showNextDayBar)

            // Refresh exactly when the price flips, and at least every 15 minutes
            // so the metrics row stays reasonably fresh.
            let switchDate = PeakClock.nextSwitches(after: now, count: 1).first?.date
                ?? now.addingTimeInterval(900)
        let refresh = min(switchDate.addingTimeInterval(5), now.addingTimeInterval(900))
        return Timeline(entries: [entry], policy: .after(refresh))
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
            fillsAvailableSpace: true,
            showsNextDayBar: entry.showsNextDayBar
        )
        .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Widget

struct DeepSeekTrackerWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "DeepSeekTrackerWidget",
            intent: TrackerWidgetConfiguration.self,
            provider: TrackerProvider()
        ) { entry in
            TrackerWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("DeepSeek Tracker")
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
