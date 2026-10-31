import Foundation

/// The two DeepSeek pricing tiers.
public enum PriceKind: String, Codable, Sendable, CaseIterable {
    /// Higher price: weekday 01:00–04:00 and 06:00–10:00 UTC.
    case peak
    /// Half price: all other time, plus Chinese weekends and public holidays all day.
    case off
}

/// One contiguous price window: a start instant, the next switch, and the billed kind.
public struct PriceWindow: Sendable, Identifiable, Equatable {
    /// First instant of the window (inclusive).
    public let start: Date
    /// First instant after the window (exclusive).
    public let end: Date
    /// Price kind billed throughout the window.
    public let kind: PriceKind
    /// Whether this is the window containing the reference instant.
    public let isCurrent: Bool

    /// Stable SwiftUI identity: the window start.
    public var id: Date { start }

    /// Length of the window in seconds.
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Creates a price window.
    public init(start: Date, end: Date, kind: PriceKind, isCurrent: Bool = false) {
        self.start = start
        self.end = end
        self.kind = kind
        self.isCurrent = isCurrent
    }
}

/// A slice of the 24-hour display timeline, measured in display-day minutes.
public struct TimelineSegment: Sendable, Identifiable, Equatable {
    /// First display minute of the segment (`0..<1440`).
    public let startMinute: Int
    /// First display minute after the segment (`0...1440`).
    public let endMinute: Int
    /// Price kind throughout the segment.
    public let kind: PriceKind

    /// Stable SwiftUI identity: the start minute.
    public var id: Int { startMinute }

    /// Creates a timeline segment.
    public init(startMinute: Int, endMinute: Int, kind: PriceKind) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.kind = kind
    }
}
