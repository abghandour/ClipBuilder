import Foundation

/// The Express reel (docs/Express-Reel-List-Plan.md): one ordered list per
/// project and source video of the items selected across the Footage sections.
extension Database {
    func fetchExpressReelItems(projectID: Int64, videoID: Int64) throws -> [MiniReelItem] {
        try connection.query("""
            SELECT kind, item_id, position, scene_id, start_time, end_time, title FROM express_reel_items
            WHERE project_id = ? AND video_id = ? ORDER BY position, id
            """, [.integer(projectID), .integer(videoID)]).compactMap { row in
            guard let kind = row["kind"]?.stringValue.flatMap(MiniWizardFlow.FootageKind.init(rawValue:)),
                  let itemID = row["item_id"]?.intValue else { return nil }
            return MiniReelItem(kind: kind, itemID: itemID, position: Int(row["position"]?.intValue ?? 0),
                                sceneID: row["scene_id"]?.intValue,
                                start: row["start_time"]?.doubleValue ?? 0, end: row["end_time"]?.doubleValue ?? 0,
                                title: row["title"]?.stringValue ?? "")
        }
    }

    /// Rewrites the reel for one project and video; the list is short.
    /// Every project's reel items of one section of a video, but for the
    /// project whose reel is open (its owner saves that one itself).
    func deleteExpressReelItems(videoID: Int64, kind: MiniWizardFlow.FootageKind, exceptProject: Int64?) throws {
        try connection.execute("DELETE FROM express_reel_items WHERE video_id = ? AND kind = ? AND project_id IS NOT ?",
                               [.integer(videoID), .text(kind.rawValue), exceptProject.map(SQLValue.integer) ?? .null])
    }

    func replaceExpressReelItems(projectID: Int64, videoID: Int64, items: [MiniReelItem]) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM express_reel_items WHERE project_id = ? AND video_id = ?",
                                   [.integer(projectID), .integer(videoID)])
            for (position, item) in items.enumerated() {
                try connection.execute("""
                    INSERT OR REPLACE INTO express_reel_items
                        (project_id, video_id, kind, item_id, position, scene_id, start_time, end_time, title)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(projectID), .integer(videoID), .text(item.kind.rawValue), .integer(item.itemID),
                          .integer(Int64(position)), item.sceneID.map(SQLValue.integer) ?? .null,
                          .real(item.start), .real(item.end), .text(item.title)])
            }
        }
    }
}
