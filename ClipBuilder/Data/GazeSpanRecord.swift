import Foundation

/// Real glance rows. The database's `none` receipt never becomes a span.
nonisolated struct GazeSpanRecord: Identifiable, Codable, Sendable, Equatable {
    var id: Int64 = 0
    var videoID: Int64
    var tile: Int
    var personKey: String?
    var start: Double
    var end: Double
    var kind: GazeMeter.Span.Kind
    var meterVersion: Int

    var span: GazeMeter.Span { .init(start: start, end: end, kind: kind) }
}
