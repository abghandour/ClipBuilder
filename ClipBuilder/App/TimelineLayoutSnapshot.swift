import Foundation

/// Row assignments and grouped timeline entries derived once for each
/// document mutation. The timeline header and lanes share this snapshot so
/// they do not independently filter, sort, and pack the same arrays.
struct TimelineLayoutSnapshot {
    struct VideoTrack {
        var clips: [TimelineClip]
        var rows: [UUID: Int]
        var rowCount: Int
    }

    var videoTracks: [VideoTrack]
    var overlayEntries: [OverlayLaneEntry]
    var overlayRows: [UUID: Int]
    var overlayRowCount: Int

    init(document: TimelineDocument) {
        var clipsByTrack = Array(repeating: [TimelineClip](), count: document.trackCount)
        for clip in document.videoTrack where clipsByTrack.indices.contains(clip.track) {
            clipsByTrack[clip.track].append(clip)
        }
        videoTracks = clipsByTrack.map { clips in
            let sorted = clips.sorted { $0.startTime < $1.startTime }
            let layout = Self.packRows(sorted.map { ($0.uid, $0.startTime, $0.startTime + $0.duration) })
            return VideoTrack(clips: clips, rows: layout.rows, rowCount: layout.rowCount)
        }

        overlayEntries = document.textOverlays.map(OverlayLaneEntry.text)
            + document.imageOverlays.map(OverlayLaneEntry.image)
            + document.overlayBlocks.map(OverlayLaneEntry.block)
        let sortedOverlays = overlayEntries.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        let overlayLayout = Self.packRows(sortedOverlays.map { ($0.uid, $0.start, $0.end) })
        overlayRows = overlayLayout.rows
        overlayRowCount = overlayLayout.rowCount
    }

    private static func packRows(_ entries: [(id: UUID, start: Double, end: Double)])
        -> (rows: [UUID: Int], rowCount: Int) {
        var rowEnds: [Double] = []
        var rows: [UUID: Int] = [:]
        rows.reserveCapacity(entries.count)
        for entry in entries {
            if let row = rowEnds.firstIndex(where: { $0 <= entry.start + 0.001 }) {
                rows[entry.id] = row
                rowEnds[row] = entry.end
            } else {
                rows[entry.id] = rowEnds.count
                rowEnds.append(entry.end)
            }
        }
        return (rows, max(1, rowEnds.count))
    }
}
