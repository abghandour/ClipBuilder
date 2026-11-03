import Foundation

/// A copy of footage added again on this Mac is linked to the row that
/// already describes it instead of registering a second, blank one, so the
/// row's scenes, transcript and project memberships carry over. The row has
/// no file here (Team Sync carries no paths; a file can be moved away) and
/// the copy is usually a re-encode, so the content hash does not match: the
/// row is found by name and duration. The hash stays, it is the team-wide
/// identity (sync key, highlight history, Drive verification).
nonisolated enum SourceRelink {
    /// Re-encodes and trimmed exports drift by fractions of a second.
    static let durationTolerance = 1.0

    /// The row a scanned file belongs to when its hash is unknown: the row
    /// already at its path (a linked file probed again), else a row whose
    /// file is not on this Mac with the same name and duration. A
    /// zero-duration row at the path is a registration that failed or
    /// caught a copy in progress; it registers afresh and the scan removes it.
    static func target(filename: String, duration: Double, path: String, in rows: [VideoRecord],
                       isLocal: (String?) -> Bool = FootageAvailability.isDownloaded) -> VideoRecord? {
        if let same = rows.first(where: { $0.path == path && $0.duration > 0 }) { return same }
        return rows.first { !isLocal($0.path) && matches($0, filename: filename, duration: duration) }
    }

    /// Rows with nothing on this Mac paired with the local row that is their
    /// re-added copy, registered under its own hash before this rule existed
    /// or while the missing row was hidden. The caller merges the pair when
    /// the local row has nothing attached yet.
    static func duplicates(in rows: [VideoRecord],
                           isLocal: (String?) -> Bool = FootageAvailability.isDownloaded) -> [(local: VideoRecord, missing: VideoRecord)] {
        let local = rows.filter { isLocal($0.path) }
        guard !local.isEmpty else { return [] }
        return rows.filter { !isLocal($0.path) }.compactMap { missing in
            local.first { matches(missing, filename: $0.filename, duration: $0.duration) }
                .map { (local: $0, missing: missing) }
        }
    }

    /// Same base name (extension and case aside) and about the same length.
    static func matches(_ row: VideoRecord, filename: String, duration: Double) -> Bool {
        guard duration > 0, row.duration > 0, abs(row.duration - duration) <= durationTolerance else { return false }
        return baseName(row.filename) == baseName(filename)
    }

    private static func baseName(_ filename: String) -> String {
        URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent.lowercased()
    }
}
