import Foundation

extension Database {
    func criticExemplarCandidates() throws -> [CriticExemplars.Candidate] {
        var candidates = try fetchGeneratedVideos().map { video in
            CriticExemplars.Candidate(id: "generated:\(video.id)", path: video.path,
                date: video.generatedAt ?? "", duration: video.duration,
                favorite: video.favorite, percentile: video.audiencePercentile,
                batchID: video.batchID, traits: try reelTraits(kind: "generated", videoID: String(video.id)))
        }
        let rows = try connection.query("""
            SELECT t.video_kind, t.video_id, t.traits_json, t.computed_at,
                   COALESCE(g.media_id, r.media_id, r.shortcode, t.video_id) AS external_id,
                   g.local_video_path AS grid_path, rg.local_video_path AS report_grid_path, e.local_path AS external_path,
                   COALESCE(g.posted_at, r.posted_at, t.computed_at) AS posted_at
            FROM reel_traits t
            LEFT JOIN ig_media g ON t.video_kind = 'instagram' AND CAST(g.id AS TEXT) = t.video_id
            LEFT JOIN ig_report_media r ON t.video_kind = 'imported' AND CAST(r.id AS TEXT) = t.video_id
            LEFT JOIN ig_media rg ON r.account_id = rg.account_id
                AND (rg.media_id = r.media_id OR rg.media_id = r.shortcode)
            LEFT JOIN imported_externals e ON e.platform = 'instagram'
                AND (e.external_id = g.media_id OR e.external_id = r.media_id
                     OR e.external_id = r.shortcode OR (t.video_kind = 'external' AND e.external_id = t.video_id))
            WHERE t.reference = 1 AND t.version = ? AND t.video_kind IN ('instagram', 'imported', 'external')
            """, [.integer(Int64(ReelTraits.version))])
        for row in rows {
            let paths = ["grid_path", "report_grid_path", "external_path"].compactMap { row[$0]?.stringValue }
            guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? paths.first,
                  let id = row["external_id"]?.stringValue,
                  let json = row["traits_json"]?.stringValue,
                  let traits = try? JSONDecoder().decode(ReelTraits.self, from: Data(json.utf8)) else { continue }
            candidates.append(.init(id: "reference:\(id)", path: path,
                date: row["posted_at"]?.stringValue ?? "", duration: traits.duration,
                reference: true, traits: traits))
        }
        return candidates
    }

    func criticExclusion(generatedID: Int64) throws -> CriticExemplars.Exclusion {
        let videos = try fetchGeneratedVideos()
        guard let video = videos.first(where: { $0.id == generatedID }) else {
            return .init(ids: ["generated:\(generatedID)"])
        }
        let siblings = videos.filter { $0.id == video.id || (video.batchID != nil && $0.batchID == video.batchID) }
        return .init(ids: Set(siblings.map { "generated:\($0.id)" }),
                     batchIDs: Set(siblings.compactMap(\.batchID)), paths: Set(siblings.map(\.path)))
    }
}

extension Database {
    func criticPreferencePairs() throws -> [CriticAgreement.Pair] {
        try connection.query("SELECT chosen_video_id, rejected_video_id FROM wizard_preferences ORDER BY id").compactMap {
            guard let chosen = $0["chosen_video_id"]?.intValue,
                  let rejected = $0["rejected_video_id"]?.intValue else { return nil }
            return .init(chosen: chosen, rejected: rejected)
        }
    }
}
