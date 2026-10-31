// Offscreen renderer for the tracker card.
//
//   ./tools/render-shots.sh   → artifacts/screens/widget-*.png at 2x
//
// Uses the collector's real metrics/metrics.json when present, else a fixture.

import SwiftUI
import AppKit

enum Wallpaper {
    static func colors(_ mode: TrackerMode) -> [Color] {
        switch mode {
        case .light: return [Color(hex: 0xE7EDF7), Color(hex: 0xC3D3E9), Color(hex: 0xAEC3DE)]
        case .dark: return [Color(hex: 0x2A3140), Color(hex: 0x161B25), Color(hex: 0x0B0E14)]
        }
    }

    static func view(_ mode: TrackerMode) -> some View {
        ZStack {
            LinearGradient(colors: colors(mode), startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [Color.white.opacity(mode == .light ? 0.55 : 0.10), .clear],
                center: .init(x: 0.25, y: 0.15),
                startRadius: 10,
                endRadius: 460
            )
        }
    }
}

enum Fixtures {
    static let peakNow = ISO8601DateFormatter().date(from: "2026-10-30T09:00:00Z")!
    static let offPeakNow = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!

    static func realMetrics() -> TrackerMetrics? {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("metrics/metrics.json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? TrackerMetrics.decode(data)
    }

    static func live() -> TrackerMetrics {
        if let real = realMetrics() { return real }
        return TrackerMetrics(
            schema: 1,
            generatedAt: peakNow.addingTimeInterval(-48),
            source: "status.deepseek.com",
            overall: .operational,
            statusLabel: "Operational",
            components: [
                ComponentMetrics(id: "flash", name: "DeepSeek V4.1 Flash API", status: .operational, uptime: 99.85),
                ComponentMetrics(id: "pro", name: "DeepSeek V4 Pro API", status: .operational, uptime: 99.62),
            ],
            activeIncidents: 0,
            latency: LatencyMetrics(ok: true, milliseconds: 214, p50Milliseconds: 198, samples: 5, endpoint: "api.deepseek.com", checkedAt: peakNow),
            balance: BalanceMetrics(available: true, currency: "USD", total: 12.34, topUp: 10, granted: 2.34, keyHint: "sk-…9f2c")
        )
    }

    static func stale() -> TrackerMetrics {
        var metrics = live()
        metrics.generatedAt = peakNow.addingTimeInterval(-20 * 60)
        return metrics
    }

    static func degraded() -> TrackerMetrics {
        var metrics = live()
        metrics.overall = .partialOutage
        metrics.activeIncidents = 1
        metrics.components[0].status = .partialOutage
        return metrics
    }
}

/// A card floating on a wallpaper, as it appears on the desktop.
struct Shot: View {
    let mode: TrackerMode
    let size: WidgetSize
    let now: Date
    let metrics: MetricsSnapshot

    var body: some View {
        ZStack {
            Wallpaper.view(mode)
            TrackerCard(
                snapshot: TrackerSnapshot(now: now),
                metrics: metrics,
                mode: mode,
                size: size,
                zoneOffsetMinutes: 0,
                showsZone: size != .small
            )
        }
        .frame(width: size.width + 132, height: size.height + 132)
    }
}

enum Renderer {
    @MainActor
    static func png(for view: some View, scale: CGFloat = 2) -> Data? {
        let renderer = ImageRenderer(content: view.environment(\.trackerRenderMode, true))
        renderer.scale = scale
        renderer.isOpaque = true
        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    @MainActor
    static func run() {
        let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/screens", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let live = MetricsSnapshot(metrics: Fixtures.live(), freshness: .live)
        let stale = MetricsSnapshot(metrics: Fixtures.stale(), freshness: .stale)
        let degraded = MetricsSnapshot(metrics: Fixtures.degraded(), freshness: .live)
        let peak = Fixtures.peakNow
        let offPeak = Fixtures.offPeakNow

        let shots: [(String, TrackerMode, WidgetSize, Date, MetricsSnapshot)] = [
            ("widget-light-small", .light, .small, peak, live),
            ("widget-dark-small", .dark, .small, peak, live),
            ("widget-light-medium", .light, .medium, peak, live),
            ("widget-dark-medium", .dark, .medium, peak, live),
            ("widget-light-large", .light, .large, peak, live),
            ("widget-dark-large", .dark, .large, peak, live),
            ("widget-light-offpeak-medium", .light, .medium, offPeak, live),
            ("widget-dark-offpeak-large", .dark, .large, offPeak, live),
            ("widget-dark-degraded-medium", .dark, .medium, peak, degraded),
            ("widget-light-stale-medium", .light, .medium, peak, stale),
            ("widget-light-weekend-medium", .light, .medium,
             ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!, live),
            ("widget-light-offline-small", .light, .small, peak, .unavailable),
            ("widget-dark-loading-medium", .dark, .medium, peak, .loading),
        ]

        var written = 0
        for (name, mode, size, instant, metrics) in shots {
            let view = Shot(mode: mode, size: size, now: instant, metrics: metrics)
            guard let data = png(for: view) else {
                FileHandle.standardError.write(Data("render failed: \(name)\n".utf8))
                continue
            }
            try? data.write(to: out.appendingPathComponent("\(name).png"))
            written += 1
        }
        print("\(written)/\(shots.count) screenshots written to \(out.path)")
    }
}

@main
struct RenderShots {
    static func main() async {
        await MainActor.run {
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)
            Renderer.run()
        }
        exit(0)
    }
}
