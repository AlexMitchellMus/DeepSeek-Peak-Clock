import SwiftUI
import WidgetKit

// MARK: - Timeline

struct TrackerEntry: TimelineEntry {
    let date: Date
    let metrics: MetricsSnapshot
}

struct TrackerProvider: TimelineProvider {
    /// Widget family this provider serves: normal, or with the rolling 24 h bar.
    let showsNextDayBar: Bool

    func placeholder(in context: Context) -> TrackerEntry {
        TrackerEntry(date: Date(), metrics: .loading)
    }

    func getSnapshot(in context: Context, completion: @escaping (TrackerEntry) -> Void) {
        if context.isPreview {
            completion(TrackerEntry(date: Date(), metrics: .unavailable))
            return
        }
        Task {
            let metrics = await MetricsFetcher.fetchForTimeline()
            completion(TrackerEntry(date: Date(), metrics: metrics))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrackerEntry>) -> Void) {
        Task {
            let now = Date()
            // Always returns something: cached metrics if the network is slow, so the
            // widget never sits in its redacted placeholder state.
            let metrics = await MetricsFetcher.fetchForTimeline()
            let entry = TrackerEntry(date: now, metrics: metrics)

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
    let showsNextDayBar: Bool

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
            showsNextDayBar: showsNextDayBar
        )
        .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Widgets

/// The standard widget.
struct DeepSeekTrackerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DeepSeekTrackerWidget", provider: TrackerProvider(showsNextDayBar: false)) { entry in
            TrackerWidgetEntryView(entry: entry, showsNextDayBar: false)
        }
        .configurationDisplayName("DeepSeek Tracker")
        .description("Countdown to DeepSeek's next off-peak price window, with the day's schedule and live API status.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

/// Same card, with a second bar covering the rolling next 24 hours.
struct DeepSeekTracker24hWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DeepSeekTrackerWidget24h", provider: TrackerProvider(showsNextDayBar: true)) { entry in
            TrackerWidgetEntryView(entry: entry, showsNextDayBar: true)
        }
        .configurationDisplayName("DeepSeek Tracker · 24h")
        .description("The standard card plus a rolling next-24-hours timeline bar underneath.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct DeepSeekTrackerWidgetBundle: WidgetBundle {
    var body: some Widget {
        DeepSeekTrackerWidget()
        DeepSeekTracker24hWidget()
    }
}
