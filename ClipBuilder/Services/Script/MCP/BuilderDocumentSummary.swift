import Foundation

/// All document lanes, paginated together. Intentionally excludes paths,
/// transcript text, resource contents and application settings.
nonisolated struct BuilderDocumentSummary: Codable, Sendable {
    struct Row: Codable, Sendable {
        var id: String
        var lane: String
        var track: Int?
        var start: Double
        var duration: Double
        var scene: Int64? = nil
    }
    var duration: Double
    var tracks: Int
    var total: Int
    var nextOffset: Int?
    var rows: [Row]

    init(document: TimelineDocument, offset: Int, limit: Int) throws {
        guard offset >= 0, (1...200).contains(limit) else { throw ScriptError.invalid("Invalid summary page.") }
        var rows = document.videoTrack.map {
            Row(id: $0.uid.uuidString, lane: "video", track: $0.track, start: $0.startTime, duration: $0.duration, scene: $0.sceneID)
        }
        rows += document.soundTrack.map { Row(id: $0.uid.uuidString, lane: "sound", start: $0.startTime, duration: $0.duration) }
        rows += document.cropBlocks.map { Row(id: $0.uid.uuidString, lane: "crop", start: $0.startTime, duration: $0.duration) }
        rows += document.overlayBlocks.map { Row(id: $0.uid.uuidString, lane: "overlay", start: $0.startTime, duration: $0.duration) }
        rows += document.textOverlays.map { Row(id: $0.uid.uuidString, lane: "text", start: $0.startTime, duration: $0.duration) }
        rows += document.imageOverlays.map { Row(id: $0.uid.uuidString, lane: "image", start: $0.startTime, duration: $0.duration) }
        rows.sort { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        self.duration = document.contentEnd
        tracks = document.trackCount
        total = rows.count
        // Avoid offset + limit overflow for hostile Int.max input.
        let start = min(offset, rows.count)
        let end = start + min(limit, rows.count - start)
        nextOffset = end < rows.count ? end : nil
        self.rows = Array(rows[start..<end])
    }
}
