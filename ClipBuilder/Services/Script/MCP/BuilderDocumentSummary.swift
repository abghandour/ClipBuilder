import Foundation

/// All document lanes, paginated together. Intentionally excludes paths,
/// transcript text, resource contents and application settings.
nonisolated struct BuilderDocumentSummary: Codable, Sendable {
    struct Row: Codable, Sendable, Equatable {
        var id: String
        var lane: String
        var track: Int?
        var start: Double
        var duration: Double
        var scene: Int64? = nil
        var name: String? = nil
        var bumperMode: BumperMode? = nil
        var volume: Int? = nil
        var position: String? = nil
        var cropFraction: Double? = nil
        var muted: Bool? = nil
        var text: String? = nil
        var x: Double? = nil
        var y: Double? = nil
        var width: Double? = nil
        var opacity: Double? = nil
        var fontsize: Int? = nil
        var fontcolor: String? = nil
        var bold: Bool? = nil
        var italic: Bool? = nil
        var design: String? = nil
    }
    struct Selection: Codable, Sendable, Equatable {
        var kind: String
        var id: String
    }
    struct Track: Codable, Sendable, Equatable {
        var index: Int
        var label: String
    }
    var selection: ScriptValue
    var playhead: Double
    var focusedTrack: ScriptValue
    var trackLabels: [Track]
    var duration: Double
    var tracks: Int
    var total: Int
    var nextOffset: Int?
    var rows: [Row]

    init(document: TimelineDocument, offset: Int, limit: Int,
         selection: TimelineSelection? = nil, playhead: Double = 0, focusedTrack: Int? = nil) throws {
        let selected: Selection?
        switch selection {
        case .clip(let id): selected = Selection(kind: "clip", id: id.uuidString)
        case .sound(let id): selected = Selection(kind: "sound", id: id.uuidString)
        case .text(let id): selected = Selection(kind: "text", id: id.uuidString)
        case .image(let id): selected = Selection(kind: "image", id: id.uuidString)
        case .overlay(let id): selected = Selection(kind: "overlay", id: id.uuidString)
        case .crop(let id): selected = Selection(kind: "crop", id: id.uuidString)
        case nil: selected = nil
        }
        self.selection = selected.map { .object(["kind": .string($0.kind), "id": .string($0.id)]) } ?? .null
        self.playhead = playhead
        self.focusedTrack = focusedTrack.map { .number(Double($0)) } ?? .null
        let labels = ["I", "II", "III", "IV", "V", "VI"]
        trackLabels = (0..<document.trackCount).map { Track(index: $0, label: labels[$0]) }
        guard offset >= 0, (1...200).contains(limit) else { throw ScriptError.invalid("Invalid summary page.") }
        let rows = Self.allRows(document: document)
        self.duration = document.contentEnd
        tracks = document.trackCount
        total = rows.count
        // Avoid offset + limit overflow for hostile Int.max input.
        let start = min(offset, rows.count)
        let end = start + min(limit, rows.count - start)
        nextOffset = end < rows.count ? end : nil
        self.rows = Array(rows[start..<end])
    }

    static func allRows(document: TimelineDocument) -> [Row] {
        var rows = document.videoTrack.map {
            Row(id: $0.uid.uuidString, lane: "video", track: $0.track, start: $0.startTime, duration: $0.duration,
                scene: $0.sceneID, bumperMode: $0.bumper ? $0.bumperMode : nil, volume: $0.volume,
                position: $0.position, cropFraction: $0.cropXFrac, muted: $0.muted)
        }
        rows += document.soundTrack.map {
            Row(id: $0.uid.uuidString, lane: "sound", start: $0.startTime, duration: $0.duration,
                name: $0.name, volume: $0.volume)
        }
        rows += document.cropBlocks.map {
            Row(id: $0.uid.uuidString, lane: "crop", start: $0.startTime, duration: $0.duration)
        }
        rows += document.overlayBlocks.map {
            Row(id: $0.uid.uuidString, lane: "overlay", start: $0.startTime, duration: $0.duration, name: $0.name)
        }
        rows += document.textOverlays.map {
            Row(id: $0.uid.uuidString, lane: "text", start: $0.startTime, duration: $0.duration,
                position: $0.position, text: String($0.text.prefix(1000)), x: $0.xFrac, y: $0.yFrac,
                opacity: $0.opacity, fontsize: $0.fontsize, fontcolor: $0.fontcolor,
                bold: $0.bold, italic: $0.italic, design: $0.design)
        }
        rows += document.imageOverlays.map {
            Row(id: $0.uid.uuidString, lane: "image", start: $0.startTime, duration: $0.duration,
                name: $0.displayName, x: $0.xFrac, y: $0.yFrac, width: $0.wFrac, opacity: $0.opacity)
        }
        rows.sort { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        return rows
    }

}
