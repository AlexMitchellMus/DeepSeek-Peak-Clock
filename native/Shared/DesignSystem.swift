import SwiftUI

/// Light or dark rendering. The widget follows the system appearance.
public enum TrackerMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case light, dark

    public var id: String { rawValue }
}

/// Every colour, radius and type size the card needs. One skin, two appearances.
public struct Palette: Sendable {
    public let mode: TrackerMode

    public let surface: Color
    public let surfaceAlt: Color
    public let text: Color
    public let textSecondary: Color
    public let textTertiary: Color
    public let hairline: Color
    public let accent: Color

    /// Off-peak green.
    public let off: Color
    /// Peak red.
    public let peak: Color
    /// Pill fill while off-peak.
    public let offPill: Color
    /// Text on `offPill`.
    public let offInk: Color
    /// Pill fill while peak.
    public let peakPill: Color
    /// Text on `peakPill`.
    public let peakInk: Color

    public let shadow: Color
    public let cornerRadius: CGFloat

    public static func of(_ mode: TrackerMode) -> Palette {
        switch mode {
        case .light:
            return Palette(
                mode: mode,
                surface: Color(hex: 0xFFFFFF, opacity: 0.80),
                surfaceAlt: Color(hex: 0x000000, opacity: 0.06),
                text: Color(hex: 0x1C1C1E),
                textSecondary: Color(hex: 0x6E6E73),
                textTertiary: Color(hex: 0x8E8E93),
                hairline: Color(hex: 0x000000, opacity: 0.09),
                accent: Color(hex: 0x0A84FF),
                off: Color(hex: 0x1DB954),
                peak: Color(hex: 0xFF3B30),
                offPill: Color(hex: 0x1DB954, opacity: 0.15),
                offInk: Color(hex: 0x116A31),
                peakPill: Color(hex: 0xFF3B30, opacity: 0.13),
                peakInk: Color(hex: 0xC0261D),
                shadow: Color(hex: 0x000000, opacity: 0.22),
                cornerRadius: 26
            )
        case .dark:
            return Palette(
                mode: mode,
                surface: Color(hex: 0x1C1C1E, opacity: 0.66),
                surfaceAlt: Color(hex: 0xFFFFFF, opacity: 0.10),
                text: Color(hex: 0xF5F5F7),
                textSecondary: Color(hex: 0xA1A1A6),
                textTertiary: Color(hex: 0x848489),
                hairline: Color(hex: 0xFFFFFF, opacity: 0.11),
                accent: Color(hex: 0x0A84FF),
                off: Color(hex: 0x30D158),
                peak: Color(hex: 0xFF453A),
                offPill: Color(hex: 0x30D158, opacity: 0.20),
                offInk: Color(hex: 0x7BEF9E),
                peakPill: Color(hex: 0xFF453A, opacity: 0.22),
                peakInk: Color(hex: 0xFFA19A),
                shadow: Color(hex: 0x000000, opacity: 0.5),
                cornerRadius: 26
            )
        }
    }

    public func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

// MARK: - Sizes

/// Widget families and their point sizes on macOS.
public enum WidgetSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case small, medium, large

    public var id: String { rawValue }

    public var width: CGFloat {
        switch self {
        case .small: return 158
        case .medium, .large: return 338
        }
    }

    public var height: CGFloat {
        switch self {
        case .small: return 158
        case .medium: return 158
        case .large: return 354
        }
    }

    public var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    public var familyName: String {
        switch self {
        case .small: return "systemSmall"
        case .medium: return "systemMedium"
        case .large: return "systemLarge"
        }
    }
}

/// Type sizes for one family — the countdown is the hero, everything else is quiet.
struct TypeScale {
    let padding: CGFloat
    let countdown: CGFloat
    let eyebrow: CGFloat
    let pill: CGFloat
    let subline: CGFloat
    let metrics: CGFloat
    let gap: CGFloat
    let barHeight: CGFloat

    static func of(_ size: WidgetSize) -> TypeScale {
        switch size {
        case .small:
            return TypeScale(padding: 12, countdown: 40, eyebrow: 9, pill: 10,
                             subline: 10.5, metrics: 9, gap: 4, barHeight: 6)
        case .medium:
            return TypeScale(padding: 15, countdown: 54, eyebrow: 10, pill: 10.5,
                             subline: 11.5, metrics: 10, gap: 5, barHeight: 8)
        case .large:
            return TypeScale(padding: 22, countdown: 104, eyebrow: 13, pill: 13,
                             subline: 15, metrics: 12.5, gap: 11, barHeight: 12)
        }
    }
}

// MARK: - Rendering mode

/// `true` while the card is rendered offscreen to a PNG (ImageRenderer cannot
/// draw `Material`, so the glass is approximated with a translucent gradient).
private struct TrackerRenderModeKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var trackerRenderMode: Bool {
        get { self[TrackerRenderModeKey.self] }
        set { self[TrackerRenderModeKey.self] = newValue }
    }
}

// MARK: - Helpers

public extension Color {
    /// Builds a colour from a 24-bit hex value and an opacity.
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

/// The floating glass card behind the widget content.
public struct CardBackground: View {
    public let palette: Palette
    public let isRendering: Bool
    /// Status wash: red while peak, green while off-peak.
    public let tint: Color

    public init(palette: Palette, isRendering: Bool, tint: Color = .clear) {
        self.palette = palette
        self.isRendering = isRendering
        self.tint = tint
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
        ZStack {
            if !isRendering {
                shape.fill(.ultraThinMaterial)
            }
            shape.fill(
                LinearGradient(
                    colors: [palette.surface.opacity(isRendering ? 1 : 0.55),
                             palette.surface.opacity(isRendering ? 1 : 0.30)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            shape.fill(
                LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0)],
                               startPoint: .topLeading, endPoint: .center)
            )
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(palette.mode == .light ? 0.75 : 0.22),
                             Color.white.opacity(palette.mode == .light ? 0.20 : 0.05)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
            shape.strokeBorder(palette.hairline, lineWidth: 1)
        }
        .compositingGroup()
        .shadow(color: palette.shadow, radius: 18, x: 0, y: 10)
    }
}
