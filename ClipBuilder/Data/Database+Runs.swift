import Foundation

nonisolated struct TextLookRunCounts: Sendable {
    struct Link: Sendable, Hashable {
        var kind: String
        var style: String
        var namedID: String
    }
    var named: [String: Int] = [:]
    var captions: [String: Int] = [:]
    var tags: [String: Int] = [:]
    var overlays: [String: Int] = [:]
}

extension Database {
    /// Aggregate saved Wizard runs without loading timelines or decoding every record.
    /// A batch is one run even when it produced multiple output videos.
    func textLookRunCounts(namedLinks: [TextLookRunCounts.Link] = []) throws -> TextLookRunCounts {
        let links = namedLinks.map { ["kind": $0.kind, "style": $0.style, "namedID": $0.namedID] }
        let linksJSON = String(decoding: try JSONSerialization.data(withJSONObject: links), as: UTF8.self)
        let rows = try connection.query(
            """
            WITH runs AS (
                SELECT COALESCE(batch_id, 'video-' || id) AS run_id,
                       CASE WHEN json_valid(settings_json) THEN settings_json ELSE '{}' END AS settings
                FROM generated_videos WHERE wizard_provider IS NOT NULL
            ), styles AS (
                SELECT run_id, 'captions' AS kind, COALESCE(json_extract(settings, '$.options.captionStyleID'), 'default') AS style FROM runs
                UNION ALL
                SELECT run_id, 'tags', COALESCE(json_extract(settings, '$.options.nameTagStyleID'), 'default') FROM runs
                UNION ALL
                SELECT run_id, 'overlays', json_extract(settings, '$.options.pinnedOverlayTemplate') FROM runs
                UNION ALL
                SELECT run_id, 'overlays', json_extract(settings, '$.options.fixedOverlayTemplate') FROM runs
            )
            SELECT kind, style, COUNT(DISTINCT run_id) AS count FROM styles
            WHERE style IS NOT NULL GROUP BY kind, style
            UNION ALL
            SELECT 'named', json_extract(link.value, '$.namedID'), COUNT(DISTINCT styles.run_id)
            FROM styles JOIN json_each(?) AS link
                ON styles.kind = json_extract(link.value, '$.kind')
                AND styles.style = json_extract(link.value, '$.style')
            GROUP BY json_extract(link.value, '$.namedID')
            """, [.text(linksJSON)])
        var result = TextLookRunCounts()
        for row in rows {
            guard let style = row["style"]?.stringValue, let count = row["count"]?.intValue else { continue }
            switch row["kind"]?.stringValue {
            case "named": result.named[style] = Int(count)
            case "captions": result.captions[style] = Int(count)
            case "tags": result.tags[style] = Int(count)
            case "overlays": result.overlays[style] = Int(count)
            default: break
            }
        }
        return result
    }
}
