import Foundation

nonisolated struct TelestrationRecord: Identifiable, Equatable, Sendable {
    var id: Int64 = 0
    var videoID: Int64
    var drawing: Telestration
    var updatedAt: Double = 0
}

extension Database {
    /// Local source annotations, independent of scoring and Team Sync.
    nonisolated static let telestrationsSchema = """
    CREATE TABLE IF NOT EXISTS telestrations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        at_time REAL NOT NULL,
        drawing_json TEXT NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS telestrations_video ON telestrations(video_id);
    """

    func fetchTelestrations(videoID: Int64) throws -> [TelestrationRecord] {
        try fetchTelestrations(videoIDs: [videoID])[videoID] ?? []
    }

    func fetchTelestrations(videoIDs: [Int64]) throws -> [Int64: [TelestrationRecord]] {
        let ids = Array(Set(videoIDs)).sorted()
        guard !ids.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try connection.query("SELECT * FROM telestrations WHERE video_id IN (\(marks)) ORDER BY at_time, id",
                                        ids.map(SQLValue.integer))
        var result: [Int64: [TelestrationRecord]] = [:]
        for row in rows {
            let id = row["id"]?.intValue ?? 0
            do {
                let drawing = try JSONDecoder().decode(Telestration.self,
                    from: Data((row["drawing_json"]?.stringValue ?? "").utf8))
                let videoID = row["video_id"]?.intValue ?? 0
                result[videoID, default: []].append(TelestrationRecord(id: id, videoID: videoID,
                    drawing: drawing, updatedAt: row["updated_at"]?.doubleValue ?? 0))
            } catch {
                ErrorLog.record("Drawing", "Skipped unreadable drawing \(id): \(error.localizedDescription)")
            }
        }
        return result
    }

    @discardableResult
    func saveTelestration(_ record: TelestrationRecord) throws -> TelestrationRecord {
        var saved = record
        let json = String(decoding: try JSONEncoder().encode(record.drawing), as: UTF8.self)
        saved.updatedAt = Date().timeIntervalSince1970
        let values: [SQLValue] = [.integer(record.videoID), .real(record.drawing.time), .text(json), .real(saved.updatedAt)]
        if record.id == 0 {
            try connection.execute("INSERT INTO telestrations(video_id, at_time, drawing_json, updated_at) VALUES (?, ?, ?, ?)", values)
            saved.id = connection.lastInsertRowID
        } else {
            // One statement: a row deleted meanwhile (another window of the
            // app) is put back with this drawing, never reported saved and lost.
            try connection.execute("""
                INSERT INTO telestrations(id, video_id, at_time, drawing_json, updated_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET video_id = excluded.video_id, at_time = excluded.at_time,
                    drawing_json = excluded.drawing_json, updated_at = excluded.updated_at
                """, [.integer(record.id)] + values)
        }
        return saved
    }

    func deleteTelestration(id: Int64) throws {
        try connection.execute("DELETE FROM telestrations WHERE id = ?", [.integer(id)])
    }
}
