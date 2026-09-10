import Foundation
import CoreGraphics

/// Row assignments and grouped timeline entries derived once for each
/// document mutation. The timeline header and lanes share this snapshot so
/// they do not independently filter, sort, and pack the same arrays.
struct TimelineLayoutSnapshot {
    /// One main-clip row's height, and the thinner band a cutaway (B-roll)
    /// strip rides in above them. Every lane, header and drag calculation
    /// reads these two numbers through the snapshot so they cannot drift.
    static let rowHeight: CGFloat = 56
    static var stripHeight: CGFloat { rowHeight * 0.55 }

    struct VideoTrack {
        /// Main clips only; cutaways ride above them in their own band.
        var clips: [TimelineClip]
        var rows: [UUID: Int]
        var rowCount: Int
        /// B-roll on this track, packed into its own rows. Empty means zero
        /// rows — the strip band disappears entirely.
        var cutaways: [TimelineClip] = []
        var cutawayRows: [UUID: Int] = [:]
        var cutawayRowCount: Int = 0

        /// Height of the whole lane: the main rows plus the strip band.
        var laneHeight: CGFloat {
            CGFloat(rowCount) * TimelineLayoutSnapshot.rowHeight
                + CGFloat(cutawayRowCount) * TimelineLayoutSnapshot.stripHeight
        }

        /// Where the main rows begin — under the strip band.
        var mainRowsOffset: CGFloat {
            CGFloat(cutawayRowCount) * TimelineLayoutSnapshot.stripHeight
        }
    }

    var videoTracks: [VideoTrack]
    /// Bumpers, in time order; drawn on the cropping row, never in a track.
    var bumpers: [TimelineClip]
    var overlayEntries: [OverlayLaneEntry]
    var overlayRows: [UUID: Int]
    var overlayRowCount: Int

    init(document: TimelineDocument) {
        var clipsByTrack = Array(repeating: [TimelineClip](), count: document.trackCount)
        var cutawaysByTrack = Array(repeating: [TimelineClip](), count: document.trackCount)
        for clip in document.videoTrack where !clip.bumper && clipsByTrack.indices.contains(clip.track) {
            if clip.isCutaway {
                cutawaysByTrack[clip.track].append(clip)
            } else {
                clipsByTrack[clip.track].append(clip)
            }
        }
        bumpers = document.videoTrack.filter(\.bumper).sorted { $0.startTime < $1.startTime }
        videoTracks = zip(clipsByTrack, cutawaysByTrack).map { clips, cutaways in
            let sorted = clips.sorted { $0.startTime < $1.startTime }
            let layout = Self.packRows(sorted.map { ($0.uid, $0.startTime, $0.startTime + $0.duration) })
            let sortedCutaways = cutaways.sorted { $0.startTime < $1.startTime }
            // No B-roll, no band: the minimum of one row is for main rows.
            let strips = Self.packRows(sortedCutaways.map { ($0.uid, $0.startTime, $0.startTime + $0.duration) },
                                       minimumRows: 0)
            return VideoTrack(clips: clips, rows: layout.rows, rowCount: layout.rowCount,
                              cutaways: cutaways, cutawayRows: strips.rows,
                              cutawayRowCount: strips.rowCount)
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

    private static func packRows(_ entries: [(id: UUID, start: Double, end: Double)],
                                 minimumRows: Int = 1)
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
        return (rows, max(minimumRows, rowEnds.count))
    }
}
