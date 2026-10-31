import SwiftUI
import WidgetKit

/// The companion app: a live preview of every widget family plus install steps.
struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("ds-size") private var sizeRaw = WidgetSize.medium.rawValue
    @AppStorage("ds-zone") private var zoneRaw = "local"

    @StateObject private var metrics = MetricsStore()
    @State private var showCollectorHelp = false

    private var size: WidgetSize { WidgetSize(rawValue: sizeRaw) ?? .medium }
    private var usesUTC: Bool { zoneRaw == "utc" }
    private var mode: TrackerMode { colorScheme == .dark ? .dark : .light }
    private var palette: Palette { Palette.of(mode) }

    var body: some View {
        HStack(spacing: 0) {
            preview
            sidebar
                .frame(width: 310)
                .background(.regularMaterial)
        }
        .ignoresSafeArea()
        .task {
            WidgetCenter.shared.reloadAllTimelines()
            await metrics.refreshLoop(every: 60)
        }
    }

    private var preview: some View {
        ZStack {
            Wallpaper(mode: mode)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                TrackerCard(
                    snapshot: TrackerSnapshot(now: context.date),
                    metrics: metrics.snapshot,
                    mode: mode,
                    size: size,
                    zoneOffsetMinutes: usesUTC ? 0 : DisplayZone.offsetMinutes(for: context.date),
                    showsZone: true
                )
                .id("\(mode.rawValue)-\(size.rawValue)")
            }
            .padding(36)
        }
        .overlay(alignment: .bottomLeading) {
            Text("\(size.title) widget · \(Int(size.width))×\(Int(size.height)) pt")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(mode == .light ? palette.textSecondary : Color.white.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(16)
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DeepSeek Peak Clock")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Time until DeepSeek's next off-peak half-price window.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                block("WIDGET SIZE") {
                    Picker("Size", selection: $sizeRaw) {
                        ForEach(WidgetSize.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Toggle("Show times in UTC", isOn: Binding(
                        get: { usesUTC },
                        set: { zoneRaw = $0 ? "utc" : "local" }
                    ))
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                }

                block("ADD THE WIDGET") {
                    VStack(alignment: .leading, spacing: 7) {
                        step("1", "Move DeepSeek Peak Clock.app to /Applications and open it once.")
                        step("2", "Right-click the desktop → Edit Widgets.")
                        step("3", "Search “DeepSeek Peak Clock” and drag a size onto the desktop.")
                    }
                    Text("If it isn't listed yet, keep the app open for a few seconds and reopen the widget gallery.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                block("LIVE METRICS") {
                    HStack(spacing: 6) {
                        Circle().fill(metricsColor).frame(width: 7, height: 7)
                        Text(metricsLabel)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button {
                            Task { await metrics.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                    }

                    Text("Status and latency come straight from DeepSeek. The optional collector below adds 90-day uptime and your balance.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(showCollectorHelp ? "Hide collector command" : "Show collector command") {
                        withAnimation(.easeInOut(duration: 0.15)) { showCollectorHelp.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))

                    Button {
                        WidgetCenter.shared.reloadAllTimelines()
                    } label: {
                        Label("Reload widget now", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.link)

                    if showCollectorHelp {
                        Text("node collector/status-collector.mjs --serve 8787 --interval 60")
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                }

                Spacer(minLength: 0)

                Text("Peak: 01:00–04:00 and 06:00–10:00 UTC. Weekends and Chinese public holidays are off-peak all day.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(22)
        }
    }

    private func block(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(number)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .background(Circle().fill(Color(hex: 0x0A84FF)))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var metricsColor: Color {
        switch metrics.snapshot.freshness {
        case .live: return Color(hex: 0x30D158)
        case .stale: return Color(hex: 0xFF9F0A)
        case .loading: return .secondary
        case .unavailable: return Color.secondary.opacity(0.5)
        }
    }

    private var metricsLabel: String {
        switch metrics.snapshot.freshness {
        case .live: return "Collector live"
        case .stale: return "Collector stale"
        case .loading: return "Loading…"
        case .unavailable: return "Collector offline"
        }
    }
}

/// Desktop-ish backdrop used behind the floating card in the app window.
struct Wallpaper: View {
    let mode: TrackerMode

    private var colors: [Color] {
        switch mode {
        case .light: return [Color(hex: 0xE7EDF7), Color(hex: 0xC3D3E9), Color(hex: 0xAEC3DE)]
        case .dark: return [Color(hex: 0x2A3140), Color(hex: 0x161B25), Color(hex: 0x0B0E14)]
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [Color.white.opacity(mode == .light ? 0.5 : 0.08), .clear],
                center: .init(x: 0.25, y: 0.15),
                startRadius: 10,
                endRadius: 520
            )
        }
    }
}
