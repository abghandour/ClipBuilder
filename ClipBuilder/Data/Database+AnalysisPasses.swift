import Foundation

extension Database {
    func fetchAnalysisPasses() throws -> [AnalysisPassRecord] {
        try connection.query("SELECT * FROM analysis_passes ORDER BY rowid").compactMap { row in
            guard let pass = AnalysisPassRecord.Pass(rawValue: row["pass"]?.stringValue ?? ""),
                  let status = AnalysisPassRecord.Status(rawValue: row["status"]?.stringValue ?? "") else { return nil }
            return AnalysisPassRecord(videoID: row["video_id"]?.intValue ?? 0, pass: pass,
                                      version: Int(row["version"]?.intValue ?? 1), status: status,
                                      startedAt: row["started_at"]?.stringValue ?? "",
                                      completedAt: row["completed_at"]?.stringValue, note: row["note"]?.stringValue,
                                      runKey: row["run_key"]?.stringValue)
        }
    }

    func startAnalysisPass(videoID: Int64, pass: AnalysisPassRecord.Pass, version: Int, runKey: String? = nil) throws -> AnalysisPassRecord {
        // Fractional epoch text preserves time and provides a unique key for rapid retries.
        let started = String(format: "%.9f", Date().timeIntervalSince1970)
        try connection.execute("""
            INSERT INTO analysis_passes(video_id, pass, version, status, started_at, run_key) VALUES (?, ?, ?, 'running', ?, ?)
            """, [.integer(videoID), .text(pass.rawValue), .integer(Int64(version)), .text(started), runKey.map(SQLValue.text) ?? .null])
        return AnalysisPassRecord(videoID: videoID, pass: pass, version: version, status: .running, startedAt: started, runKey: runKey)
    }

    func finishAnalysisPass(_ pass: AnalysisPassRecord, status: AnalysisPassRecord.Status, note: String? = nil) throws {
        try connection.execute("""
            UPDATE analysis_passes SET status = ?, completed_at = ?, note = ?
            WHERE video_id = ? AND pass = ? AND started_at = ?
            """, [.text(status.rawValue), status == .running ? .null : .text(Date().ISO8601Format()),
                  note.map(SQLValue.text) ?? .null, .integer(pass.videoID), .text(pass.pass.rawValue), .text(pass.startedAt)])
    }
}
