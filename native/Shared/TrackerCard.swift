import SwiftUI

/// A metrics reading plus the loading state the card must render for it.
public struct MetricsSnapshot: Sendable {
    /// The decoded payload, when one has been loaded.
    public var metrics: TrackerMetrics?
    /// Loading / live / stale / unavailable.
    public var freshness: Freshness
    /// Short explanation shown in the unavailable state.
    public var detail: String?

    public init(metrics: TrackerMetrics? = nil, freshness: Freshness = .unavailable, detail: String? = nil) {
        self.metrics = metrics
        self.freshness = freshness
        self.detail = detail
    }

    /// Nothing has loaded yet.
    public static let loading = MetricsSnapshot(metrics: nil, freshness: .loading, detail: nil)
    /// No collector has ever answered.
    public static let unavailable = MetricsSnapshot(freshness: .unavailable, detail: "metrics offline")

    /// Age label, e.g. `"20m ago"`.
    public func ageLabel(now: Date) -> String {
        guard let generated = metrics?.generatedAt else { return "no data" }
        let minutes = Int(max(0, now.timeIntervalSince(generated)) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}

/// The widget card: one big countdown to the next price change, plus state and metrics.
///
/// Pure: everything is derived from `snapshot` + `metrics`, no timers, no globals.
public struct TrackerCard: View {
    public let snapshot: TrackerSnapshot
    public let metrics: MetricsSnapshot
    public let mode: TrackerMode
    public let size: WidgetSize
    /// Minutes east of UTC used for every label.
    public let zoneOffsetMinutes: Int
    /// Show the display zone in the header.
    public let showsZone: Bool
    /// Widget mode: let the system animate the countdown.
    public let liveCountdown: Bool
    /// Pin to the family's point size (previews, screenshots) or fill the widget area.
    public let fillsAvailableSpace: Bool

    @Environment(\.trackerRenderMode) private var isRendering

    public init(
        snapshot: TrackerSnapshot,
        metrics: MetricsSnapshot = .loading,
        mode: TrackerMode = .light,
        size: WidgetSize = .medium,
        zoneOffsetMinutes: Int = DisplayZone.offsetMinutes(for: Date()),
        showsZone: Bool = true,
        liveCountdown: Bool = false,
        fillsAvailableSpace: Bool = false
    ) {
        self.snapshot = snapshot
        self.metrics = metrics
        self.mode = mode
        self.size = size
        self.zoneOffsetMinutes = zoneOffsetMinutes
        self.showsZone = showsZone
        self.liveCountdown = liveCountdown
        self.fillsAvailableSpace = fillsAvailableSpace
    }

    private var palette: Palette { Palette.of(mode) }
    private var scale: TypeScale { TypeScale.of(size) }
    private var tint: Color { snapshot.kind == .peak ? palette.peak : palette.off }

    public var body: some View {
        let p = palette
        let s = scale
        VStack(alignment: .leading, spacing: 0) {
            header(p, s)
                .padding(.bottom, size == .large ? 0 : s.gap)

            if size == .large { Spacer(minLength: 0) }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(eyebrow)
                    .font(p.font(s.eyebrow, .semibold))
                    .tracking(s.eyebrow * 0.10)
                    .foregroundStyle(p.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if size != .small {
                    Text(dayBadge)
                        .font(p.font(s.eyebrow * 0.92, .medium))
                        .tracking(0.4)
                        .foregroundStyle(p.textTertiary)
                        .lineLimit(1)
                }
            }

            countdown(p, s)
                .padding(.top, s.gap * 0.12)

            Text(subline)
                .font(p.font(s.subline, .medium))
                .foregroundStyle(p.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            scheduleBar(p, s)
                .padding(.top, s.gap * 0.85)

            Spacer(minLength: s.gap)

            metricsBlock(p, s)
        }
        .padding(s.padding)
        .modifier(CardFrame(size: size, fills: fillsAvailableSpace))
        .background(CardBackground(palette: p, isRendering: isRendering, tint: tint))
        .clipShape(RoundedRectangle(cornerRadius: p.cornerRadius, style: .continuous))
        .environment(\.colorScheme, mode == .dark ? .dark : .light)
    }

    // MARK: header

    private func header(_ p: Palette, _ s: TypeScale) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: s.pill * 0.5) {
                Circle()
                    .fill(snapshot.kind == .peak ? p.peak : p.off)
                    .frame(width: s.pill * 0.62, height: s.pill * 0.62)
                Text(pillText)
                    .font(p.font(s.pill, .semibold))
                    .tracking(0.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(snapshot.kind == .peak ? p.peakInk : p.offInk)
            .padding(.horizontal, s.pill * 0.85)
            .padding(.vertical, s.pill * 0.42)
            .background(
                Capsule(style: .continuous)
                    .fill(snapshot.kind == .peak ? p.peakPill : p.offPill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder((snapshot.kind == .peak ? p.peak : p.off).opacity(0.18), lineWidth: 0.5)
            )

            Spacer(minLength: 2)

            if showsZone {
                Text(DisplayZone.label(offsetMinutes: zoneOffsetMinutes))
                    .font(p.font(s.eyebrow * 0.92, .medium))
                    .tracking(0.5)
                    .foregroundStyle(p.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: countdown

    private func countdown(_ p: Palette, _ s: TypeScale) -> some View {
        countdownText
            .font(p.font(s.countdown, .semibold))
            .monospacedDigit()
            .kerning(s.countdown * -0.025)
            .foregroundStyle(p.text)
            .lineLimit(1)
            .minimumScaleFactor(0.34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(eyebrow) \(snapshot.countdownText)")
    }

    @ViewBuilder private var countdownText: some View {
        if liveCountdown, snapshot.window.end > snapshot.now {
            Text(timerInterval: snapshot.now...snapshot.window.end, countsDown: true)
        } else {
            Text(snapshot.countdownText)
        }
    }

    // MARK: schedule bar

    /// The day's peak/off-peak schedule in the display zone, with a "now" notch.
    private func scheduleBar(_ p: Palette, _ s: TypeScale) -> some View {
        let segments = snapshot.segments(offsetMinutes: zoneOffsetMinutes)
        let nowFraction = CGFloat(DisplayZone.minuteOfDay(snapshot.now, offsetMinutes: zoneOffsetMinutes)) / 1440

        return VStack(spacing: s.gap * 0.45) {
            Canvas { context, size in
                let barHeight = s.barHeight
                let y = (size.height - barHeight) / 2
                let gap: CGFloat = 1.5

                for segment in segments {
                    let start = CGFloat(segment.startMinute) / 1440 * size.width
                    let end = CGFloat(segment.endMinute) / 1440 * size.width
                    let rect = CGRect(x: start + gap / 2, y: y,
                                      width: max(1.5, end - start - gap), height: barHeight)
                    let color = segment.kind == .peak ? p.peak : p.off
                    context.fill(Path(roundedRect: rect, cornerRadius: barHeight / 2),
                                 with: .color(color.opacity(0.9)))
                }

                let x = nowFraction * size.width
                let marker = CGRect(x: x - 1.5, y: y - 3.5, width: 3, height: barHeight + 7)
                context.fill(Path(roundedRect: marker.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 3),
                             with: .color(.black.opacity(0.20)))
                context.fill(Path(roundedRect: marker, cornerRadius: 1.5), with: .color(.white))
                context.stroke(Path(roundedRect: marker, cornerRadius: 1.5),
                               with: .color(.black.opacity(0.16)), lineWidth: 0.5)
            }
            .frame(height: s.barHeight + 7)
            .accessibilityHidden(true)

            if size != .small {
                HStack(spacing: 0) {
                    ForEach(Array(axisTicks.enumerated()), id: \.offset) { index, tick in
                        Text(tick.label)
                            .font(p.font(s.metrics * 0.92, .medium))
                            .foregroundStyle(p.textTertiary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: axisAlignment(index))
                    }
                }
            }
        }
    }

    private var axisTicks: [(fraction: CGFloat, label: String)] {
        [0, 360, 720, 1080].map { minute in
            (CGFloat(minute) / 1440,
             DisplayZone.axisLabel(minute: minute, now: snapshot.now, offsetMinutes: zoneOffsetMinutes))
        }
    }

    private func axisAlignment(_ index: Int) -> Alignment {
        if index == 0 { return .leading }
        if index == axisTicks.count - 1 { return .trailing }
        return .center
    }

    // MARK: metrics

    private func metricsBlock(_ p: Palette, _ s: TypeScale) -> some View {
        VStack(alignment: .leading, spacing: s.gap * 0.35) {
            HStack(spacing: s.metrics * 0.42) {
                switch metrics.freshness {
                case .loading:
                    Circle()
                        .fill(p.textTertiary.opacity(0.3))
                        .frame(width: s.metrics * 0.62, height: s.metrics * 0.62)
                    shimmer(p, s, width: s.metrics * 9)
                    Spacer(minLength: 0)
                    shimmer(p, s, width: s.metrics * 4)

                case .live, .stale:
                    let dim = metrics.freshness == .stale
                    Circle()
                        .fill(statusColor(p).opacity(dim ? 0.55 : 1))
                        .frame(width: s.metrics * 0.62, height: s.metrics * 0.62)
                    Text(statusTitle)
                        .font(p.font(s.metrics, .semibold))
                        .foregroundStyle(p.text.opacity(dim ? 0.6 : 1))
                        .lineLimit(1)
                    if let uptime = uptimeText, size != .small {
                        separator(p, s)
                        Text(uptime)
                            .font(p.font(s.metrics, .regular))
                            .monospacedDigit()
                            .foregroundStyle(p.textSecondary.opacity(dim ? 0.6 : 1))
                    }
                    if let latency = latencyText {
                        separator(p, s)
                        Text(latency)
                            .font(p.font(s.metrics, .regular))
                            .monospacedDigit()
                            .foregroundStyle(p.textSecondary.opacity(dim ? 0.6 : 1))
                    }
                    Spacer(minLength: 0)
                    if dim {
                        Text(metrics.ageLabel(now: snapshot.now))
                            .font(p.font(s.metrics * 0.92, .regular))
                            .foregroundStyle(p.textTertiary)
                            .lineLimit(1)
                    }

                case .unavailable:
                    Circle()
                        .fill(p.textTertiary.opacity(0.45))
                        .frame(width: s.metrics * 0.62, height: s.metrics * 0.62)
                    Text("Metrics offline")
                        .font(p.font(s.metrics, .medium))
                        .foregroundStyle(p.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .lineLimit(1)

            if size == .large, let detail = detailLine {
                Text(detail)
                    .font(p.font(s.metrics * 0.95, .regular))
                    .foregroundStyle(p.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: derived

    private var pillText: String {
        snapshot.kind == .peak
            ? (size == .small ? "Peak" : "Peak pricing")
            : (size == .small ? "Off-peak" : "Off-peak · half price")
    }

    /// Which day the schedule bar is showing, and whether that whole day is off-peak.
    private var dayBadge: String {
        let day = DisplayZone.weekdayLabel(snapshot.now, offsetMinutes: zoneOffsetMinutes)
        let segments = snapshot.segments(offsetMinutes: zoneOffsetMinutes)
        let hasPeak = segments.contains { $0.kind == .peak }
        return hasPeak ? day : day + " · OFF-PEAK ALL DAY"
    }

    private var eyebrow: String {
        if size == .small {
            return snapshot.kind == .peak ? "UNTIL OFF-PEAK" : "UNTIL PEAK"
        }
        return snapshot.kind == .peak ? "UNTIL OFF-PEAK PRICING" : "UNTIL PEAK PRICING"
    }

    private var subline: String {
        guard let next = snapshot.nextSwitch else { return "no switch scheduled" }
        let verb = next.kind == .peak ? "Peak starts" : "Off-peak starts"
        return verb + " " + DisplayZone.switchLabel(next.date, now: snapshot.now, offsetMinutes: zoneOffsetMinutes)
    }

    private var uptimeText: String? {
        guard let uptime = metrics.metrics?.components.compactMap(\.uptime).first else { return nil }
        return String(format: "%.2f%%", uptime)
    }

    private var latencyText: String? {
        guard let ms = metrics.metrics?.latency?.milliseconds else { return nil }
        return "\(Int(ms.rounded())) ms"
    }

    private var statusTitle: String {
        guard let m = metrics.metrics else { return "Status unknown" }
        switch m.overall {
        case .operational: return "Operational"
        case .degraded: return "Degraded"
        case .partialOutage: return "Partial outage"
        case .fullOutage: return "Outage"
        case .maintenance: return "Maintenance"
        case .unknown: return "Status unknown"
        }
    }

    private var detailLine: String? {
        guard let m = metrics.metrics else { return nil }
        var parts: [String] = []
        if !m.components.isEmpty { parts.append("\(m.components.count) services") }
        parts.append("\(m.activeIncidents) incidents")
        if let balance = m.balance, balance.available, let total = balance.total {
            let symbol = balance.currency == "USD" ? "$" : ""
            parts.append(symbol + String(format: "%.2f", total) + " credit")
        }
        return parts.joined(separator: " · ")
    }

    private func statusColor(_ p: Palette) -> Color {
        guard let m = metrics.metrics else { return p.textTertiary }
        switch m.overall {
        case .operational: return p.off
        case .degraded: return Color(hex: 0xFF9F0A)
        case .partialOutage, .fullOutage: return p.peak
        case .maintenance: return p.accent
        case .unknown: return p.textTertiary
        }
    }

    private func separator(_ p: Palette, _ s: TypeScale) -> some View {
        Text("·")
            .font(p.font(s.metrics, .regular))
            .foregroundStyle(p.textTertiary)
    }

    private func shimmer(_ p: Palette, _ s: TypeScale, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(p.textTertiary.opacity(0.18))
            .frame(width: width, height: s.metrics * 0.7)
    }
}

/// Pins a card to its family size, or lets it fill the widget's content area.
struct CardFrame: ViewModifier {
    let size: WidgetSize
    let fills: Bool

    func body(content: Content) -> some View {
        if fills {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            content.frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }
}
