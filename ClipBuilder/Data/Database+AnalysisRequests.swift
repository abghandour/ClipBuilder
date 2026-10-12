import Foundation

extension Database {
    /// Fill the exchange layer of an existing successful batch without
    /// re-running its scene or people passes. Empty output is still a receipt.
    func addAnalysisExchanges(run: AnalysisRun, ranges: [String: [(start: Double, end: Double)]]) throws {
        try connection.transaction {
            for (tag, spans) in ranges {
                for span in spans {
                    let id = try connection.query("""
                        INSERT INTO scenes (video_id, run_id, start_time, end_time)
                        VALUES (?, ?, ?, ?) ON CONFLICT(video_id, run_id, start_time, end_time)
                        DO UPDATE SET video_id = video_id RETURNING id
                        """, [.integer(run.videoID), .integer(run.id), .real(span.start), .real(span.end)]).first?["id"]?.intValue
                    if let id {
                        try connection.execute("INSERT OR IGNORE INTO scene_tags (scene_id, tag) VALUES (?, ?)", [.integer(id), .text(tag)])
                    }
                }
            }
        }
    }

    /// Replace a run's stored request, e.g. once the run inferred the video type.
    func updateAnalysisRunRequest(id: Int64, request: AnalysisRequest) throws {
        try connection.execute("UPDATE analysis_runs SET request_hash = ?, request_json = ? WHERE id = ?",
                               [.text(request.fingerprint), .text(request.json), .integer(id)])
    }
}
