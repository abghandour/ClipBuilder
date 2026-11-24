import Foundation

extension Database {
    func replaceGazeSpans(videoID: Int64, tile: Int, personKey: String?,
                          spans: [GazeMeter.Span], meterVersion: Int) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM gaze_spans WHERE video_id = ? AND tile = ?",
                                   [.integer(videoID), .integer(Int64(tile))])
            try insertGazeSpans(videoID: videoID, tile: tile, personKey: personKey,
                                spans: spans, meterVersion: meterVersion)
        }
    }

    /// Commit all feeds and the local receipt together. Until then, cancellation
    /// leaves the previous measurement intact, never a partly measured recording.
    func finishGazeMeasurement(_ pass: AnalysisPassRecord, tiles: [GazeAnalysis.TileResult]) throws {
        try Task.checkCancellation()
        try connection.transaction {
            try connection.execute("DELETE FROM gaze_spans WHERE video_id = ?", [.integer(pass.videoID)])
            for tile in tiles {
                try Task.checkCancellation()
                try insertGazeSpans(videoID: pass.videoID, tile: tile.tile, personKey: tile.personKey,
                                    spans: tile.spans, meterVersion: GazeMeter.meterVersion)
            }
            try Task.checkCancellation()
            try finishAnalysisPass(pass, status: .completed)
        }
    }

    private func insertGazeSpans(videoID: Int64, tile: Int, personKey: String?,
                                 spans: [GazeMeter.Span], meterVersion: Int) throws {
        let rows = spans.isEmpty ? [(0.0, 0.0, "none")] : spans.map { ($0.start, $0.end, $0.kind.rawValue) }
        for (start, end, kind) in rows {
            try connection.execute("""
                INSERT INTO gaze_spans(video_id, tile, person_key, start_time, end_time, kind, meter_version)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [.integer(videoID), .integer(Int64(tile)), personKey.map(SQLValue.text) ?? .null,
                      .real(start), .real(end), .text(kind), .integer(Int64(meterVersion))])
        }
    }

    func fetchGazeSpans(videoID: Int64) throws -> [GazeSpanRecord] {
        try connection.query("""
            SELECT * FROM gaze_spans WHERE video_id = ? AND kind != 'none' ORDER BY tile, start_time, id
            """, [.integer(videoID)]).compactMap { row in
                guard let kind = GazeMeter.Span.Kind(rawValue: row["kind"]?.stringValue ?? "") else { return nil }
                return GazeSpanRecord(id: row["id"]?.intValue ?? 0, videoID: videoID,
                    tile: Int(row["tile"]?.intValue ?? 0), personKey: row["person_key"]?.stringValue,
                    start: row["start_time"]?.doubleValue ?? 0, end: row["end_time"]?.doubleValue ?? 0,
                    kind: kind, meterVersion: Int(row["meter_version"]?.intValue ?? 0))
            }
    }

    func gazeMeasured(videoID: Int64, meterVersion: Int) throws -> Bool {
        try !connection.query("SELECT 1 FROM gaze_spans WHERE video_id = ? AND meter_version = ? LIMIT 1",
            [.integer(videoID), .integer(Int64(meterVersion))]).isEmpty
    }

    /// Gaze belongs to the recording's saved feeds, independently of which
    /// transcript is active (video(id:) may hide feeds from another transcript).
    func gazeRecording(videoID: Int64) throws -> VideoRecord? {
        try connection.query("SELECT * FROM videos WHERE id = ?", [.integer(videoID)]).first.map(Self.videoRecord)
    }

    func gazeAwayShare(videoID: Int64) throws -> Double? {
        guard try gazeMeasured(videoID: videoID, meterVersion: GazeMeter.meterVersion),
              let video = try gazeRecording(videoID: videoID) else { return nil }
        return GazeReport.summary(try fetchGazeSpans(videoID: videoID), range: 0...max(0, video.duration),
                                  separateFeeds: GazeAnalysis.usesSeparateFeeds(video)).share
    }
}
