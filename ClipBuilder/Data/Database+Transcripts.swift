import Foundation

extension Database {
    // MARK: - Transcripts

    /// Availability only: return one ID per video without materializing
    /// transcript text, word timestamps, or translated rows.
    func videoIDsWithOriginalTranscripts() throws -> Set<Int64> {
        let rows = try connection.query("""
            SELECT v.id AS video_id FROM videos v
            WHERE EXISTS (
                SELECT 1 FROM transcripts t
                WHERE t.video_id = v.id AND t.is_translation = 0
            )
            """)
        return Set(rows.compactMap { $0["video_id"]?.intValue })
    }

    /// `seconds` is how long the pass that produced these segments took; it
    /// is stamped on every row and, for the original language, on the video.
    func replaceTranscripts(videoID: Int64, language: String, isTranslation: Bool,
                            segments: [TranscriptSegment], provider: String?, model: String?, technique: String? = nil,
                            seconds: TimeInterval? = nil) throws {
        // One transaction: long videos have thousands of segments, and the
        // delete + inserts must land atomically.
        try connection.transaction {
            if !isTranslation {
                if let seconds {
                    try connection.execute("UPDATE videos SET speech_seconds = ? WHERE id = ?",
                                           [.real(seconds), .integer(videoID)])
                }
                // A new transcription replaces the rows a re-cut backed up:
                // Undo must never bring an older transcription back.
                try connection.execute("DELETE FROM transcript_backups WHERE video_id = ?", [.integer(videoID)])
            }
            try connection.execute("DELETE FROM transcripts WHERE video_id = ? AND language = ? AND is_translation = ?",
                                   [.integer(videoID), .text(language), .integer(isTranslation ? 1 : 0)])
            let encoder = JSONEncoder()
            for segment in segments {
                let wordsJSON = segment.words.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
                try connection.execute("""
                    INSERT INTO transcripts (video_id, language, is_translation, start_time, end_time, text, words, provider, model, technique, seconds)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(videoID), .text(language), .integer(isTranslation ? 1 : 0),
                          .real(segment.start), .real(segment.end), .text(segment.text),
                          wordsJSON.map(SQLValue.text) ?? .null,
                          provider.map(SQLValue.text) ?? .null,
                          model.map(SQLValue.text) ?? .null, technique.map(SQLValue.text) ?? .null,
                          seconds.map(SQLValue.real) ?? .null])
            }
        }
    }

    func fetchTranscripts(videoID: Int64) throws -> [TranscriptRow] {
        try connection.query("SELECT * FROM transcripts WHERE video_id = ? ORDER BY is_translation, start_time",
                             [.integer(videoID)]).map {
            TranscriptRow(id: $0["id"]?.intValue ?? 0,
                          videoID: $0["video_id"]?.intValue ?? 0,
                          language: $0["language"]?.stringValue ?? "",
                          isTranslation: $0["is_translation"]?.boolValue ?? false,
                          startTime: $0["start_time"]?.doubleValue ?? 0,
                          endTime: $0["end_time"]?.doubleValue ?? 0,
                          text: $0["text"]?.stringValue ?? "",
                          originalText: $0["original_text"]?.stringValue,
                          wordsJSON: $0["words"]?.stringValue,
                          provider: $0["provider"]?.stringValue,
                          model: $0["model"]?.stringValue, technique: $0["technique"]?.stringValue,
                          seconds: $0["seconds"]?.doubleValue,
                          speakerKey: $0["speaker_key"]?.stringValue)
        }
    }

    /// Replace a video's original-language rows with their per-speaker
    /// re-cut. The rows as they were are kept in `transcript_backups` (the
    /// first backup wins, so Undo always returns to the transcriber's cut);
    /// translations are untouched.
    func recutTranscript(videoID: Int64, pieces: [TranscriptSpeakerRecut.Piece]) throws {
        let current = try fetchTranscripts(videoID: videoID).filter { !$0.isTranslation }
        guard !current.isEmpty, !pieces.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let encoder = JSONEncoder()
        let backup = String(decoding: try encoder.encode(current), as: UTF8.self)
        try connection.transaction {
            try connection.execute("INSERT OR IGNORE INTO transcript_backups (video_id, json) VALUES (?, ?)",
                                   [.integer(videoID), .text(backup)])
            try connection.execute("DELETE FROM transcripts WHERE video_id = ? AND is_translation = 0", [.integer(videoID)])
            for piece in pieces {
                let source = byID[piece.sourceRowID]
                let wordsJSON = piece.words.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
                // A row passed through whole keeps its edit history; a split
                // row never had one (edited rows are not split).
                let originalText = piece.split ? nil : source?.originalText
                try connection.execute("""
                    INSERT INTO transcripts (video_id, language, is_translation, start_time, end_time, text, original_text,
                                             words, provider, model, technique, seconds, speaker_key)
                    VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(videoID), .text(source?.language ?? ""),
                          .real(piece.start), .real(piece.end), .text(piece.text),
                          originalText.map(SQLValue.text) ?? .null,
                          wordsJSON.map(SQLValue.text) ?? .null,
                          source?.provider.map(SQLValue.text) ?? .null,
                          source?.model.map(SQLValue.text) ?? .null,
                          source?.technique.map(SQLValue.text) ?? .null,
                          source?.seconds.map(SQLValue.real) ?? .null,
                          piece.speakerKey.map(SQLValue.text) ?? .null])
            }
        }
    }

    func hasTranscriptBackup(videoID: Int64) throws -> Bool {
        try !connection.query("SELECT 1 FROM transcript_backups WHERE video_id = ?", [.integer(videoID)]).isEmpty
    }

    /// The transcriber's rows as a re-cut backed them up; nil without one.
    func transcriptBackup(videoID: Int64) throws -> [TranscriptRow]? {
        guard let json = try connection.query("SELECT json FROM transcript_backups WHERE video_id = ?",
                                              [.integer(videoID)]).first?["json"]?.stringValue else { return nil }
        return try JSONDecoder().decode([TranscriptRow].self, from: Data(json.utf8))
    }

    /// The rows a re-cut should plan from. Cutting from the transcriber's
    /// own rows keeps a second re-cut (better turns, a fix) from compounding
    /// the first, so the backup is put back first — unless the user has
    /// corrected text or speakers since, which the backup would erase: then
    /// the current rows are the base and stay as they are.
    func transcriptRecutBase(videoID: Int64) throws -> [TranscriptRow] {
        let current = try fetchTranscripts(videoID: videoID)
        if let backup = try transcriptBackup(videoID: videoID),
           !TranscriptSpeakerRecut.hasEdits(current, beyond: backup) {
            _ = try restoreTranscriptBackup(videoID: videoID)
            return try fetchTranscripts(videoID: videoID)
        }
        return current
    }

    /// Put the transcriber's rows back and drop the backup. False when
    /// there is nothing to restore.
    func restoreTranscriptBackup(videoID: Int64) throws -> Bool {
        guard let json = try connection.query("SELECT json FROM transcript_backups WHERE video_id = ?",
                                              [.integer(videoID)]).first?["json"]?.stringValue else { return false }
        let rows = try JSONDecoder().decode([TranscriptRow].self, from: Data(json.utf8))
        try connection.transaction {
            try connection.execute("DELETE FROM transcripts WHERE video_id = ? AND is_translation = 0", [.integer(videoID)])
            for row in rows {
                try connection.execute("""
                    INSERT INTO transcripts (video_id, language, is_translation, start_time, end_time, text, original_text,
                                             words, provider, model, technique, seconds, speaker_key)
                    VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(videoID), .text(row.language), .real(row.startTime), .real(row.endTime),
                          .text(row.text), row.originalText.map(SQLValue.text) ?? .null,
                          row.wordsJSON.map(SQLValue.text) ?? .null,
                          row.provider.map(SQLValue.text) ?? .null, row.model.map(SQLValue.text) ?? .null,
                          row.technique.map(SQLValue.text) ?? .null, row.seconds.map(SQLValue.real) ?? .null,
                          row.speakerKey.map(SQLValue.text) ?? .null])
            }
            try connection.execute("DELETE FROM transcript_backups WHERE video_id = ?", [.integer(videoID)])
        }
        return true
    }

    /// Set who says these lines (nil restores the automatic attribution).
    func setTranscriptSpeaker(ids: [Int64], speaker: TranscriptRow.SpeakerAttribution) throws {
        guard !ids.isEmpty else { return }
        try connection.transaction {
            for id in ids {
                try connection.execute("UPDATE transcripts SET speaker_key = ? WHERE id = ?",
                                       [speaker.stored.map(SQLValue.text) ?? .null, .integer(id)])
            }
        }
    }

    /// Transcript segments overlapping [start, end] for one video — used for
    /// caption burn-in of a clip.
    func transcriptSegments(videoID: Int64, start: Double, end: Double,
                            language: String? = nil) throws -> [TranscriptSegment] {
        let rows: [SQLRow]
        if let language, !language.isEmpty {
            rows = try connection.query("""
                SELECT start_time, end_time, text FROM transcripts
                WHERE video_id = ? AND is_translation = 1 AND language = ?
                    AND end_time > ? AND start_time < ?
                ORDER BY start_time
                """, [.integer(videoID), .text(language), .real(start), .real(end)])
            if rows.isEmpty {
                return try transcriptSegments(videoID: videoID, start: start, end: end, language: nil)
            }
        } else {
            rows = try connection.query("""
                SELECT start_time, end_time, text FROM transcripts
                WHERE video_id = ? AND is_translation = 0 AND end_time > ? AND start_time < ?
                ORDER BY start_time
                """, [.integer(videoID), .real(start), .real(end)])
        }
        return rows.map {
            TranscriptSegment(start: $0["start_time"]?.doubleValue ?? 0,
                              end: $0["end_time"]?.doubleValue ?? 0,
                              text: $0["text"]?.stringValue ?? "",
                              words: nil)
        }
    }

    /// Edit transcript text in place, preserving the pristine original once.
    func updateTranscriptText(id: Int64, text: String) throws {
        try connection.execute("""
            UPDATE transcripts
            SET original_text = COALESCE(original_text, text), text = ?
            WHERE id = ?
            """, [.text(text), .integer(id)])
    }

    /// Apply several edited segment texts in one transaction (the
    /// whole-transcript editor's Save).
    func updateTranscriptTexts(_ changes: [(id: Int64, text: String)]) throws {
        try connection.transaction {
            for change in changes {
                try updateTranscriptText(id: change.id, text: change.text)
            }
        }
    }

    func revertTranscriptText(id: Int64) throws {
        try connection.execute("""
            UPDATE transcripts SET text = original_text, original_text = NULL
            WHERE id = ? AND original_text IS NOT NULL
            """, [.integer(id)])
    }

    /// Rewrite a video's transcript features and cleanup proposals. A
    /// proposal the user already accepted or rejected keeps its decision
    /// when the fresh analysis proposes the same range again (within 0.25 s
    /// at either end); only still-pending rows are replaced outright.
    func replaceTranscriptFeatures(videoID: Int64, features: [TranscriptFeatureSegment],
                                   proposals: [EditProposal]) throws {
        try connection.transaction {
            let decided = try connection.query("""
                SELECT kind, start_time, end_time, decision FROM edit_proposals
                WHERE video_id = ? AND decision != 'pending'
                  AND kind IN ('silence', 'filler', 'falseStart', 'noise')
                """, [.integer(videoID)]).compactMap { row -> (kind: String, start: Double, end: Double, decision: String)? in
                guard let kind = row["kind"]?.stringValue, let start = row["start_time"]?.doubleValue,
                      let end = row["end_time"]?.doubleValue, let decision = row["decision"]?.stringValue
                else { return nil }
                return (kind, start, end, decision)
            }
            try connection.execute("DELETE FROM transcript_features WHERE video_id = ?", [.integer(videoID)])
            try connection.execute("DELETE FROM edit_proposals WHERE video_id = ? AND kind IN ('silence', 'filler', 'falseStart', 'noise')",
                                   [.integer(videoID)])
            for feature in features {
                try connection.execute("""
                    INSERT INTO transcript_features
                        (video_id, start_time, end_time, text, speaker_key, energy, kind)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(videoID), .real(feature.startTime), .real(feature.endTime),
                          .text(feature.text), feature.speakerKey.map(SQLValue.text) ?? .null,
                          .real(feature.energy), .text(feature.kind.rawValue)])
            }
            for proposal in proposals {
                let kept = decided.first {
                    $0.kind == proposal.kind.rawValue
                        && abs($0.start - proposal.startTime) <= 0.25
                        && abs($0.end - proposal.endTime) <= 0.25
                }
                try connection.execute("""
                    INSERT INTO edit_proposals
                        (video_id, kind, start_time, end_time, reason, decision)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, [.integer(videoID), .text(proposal.kind.rawValue),
                          .real(proposal.startTime), .real(proposal.endTime),
                          .text(proposal.reason), .text(kept?.decision ?? proposal.decision.rawValue)])
            }
        }
    }

    func fetchTranscriptFeatures(videoID: Int64) throws -> [TranscriptFeatureSegment] {
        try connection.query("SELECT * FROM transcript_features WHERE video_id = ? ORDER BY start_time", [.integer(videoID)]).compactMap { row in
            guard let kind = TranscriptFeatureSegment.Kind(rawValue: row["kind"]?.stringValue ?? "") else { return nil }
            return TranscriptFeatureSegment(id: row["id"]?.intValue ?? 0, videoID: videoID,
                                            startTime: row["start_time"]?.doubleValue ?? 0,
                                            endTime: row["end_time"]?.doubleValue ?? 0,
                                            text: row["text"]?.stringValue ?? "",
                                            speakerKey: row["speaker_key"]?.stringValue,
                                            energy: row["energy"]?.doubleValue ?? 0, kind: kind)
        }
    }

    func fetchEditProposals(videoID: Int64) throws -> [EditProposal] {
        try connection.query("SELECT * FROM edit_proposals WHERE video_id = ? ORDER BY start_time", [.integer(videoID)]).compactMap { row in
            guard let kind = EditProposal.Kind(rawValue: row["kind"]?.stringValue ?? ""),
                  let decision = EditProposal.Decision(rawValue: row["decision"]?.stringValue ?? "") else { return nil }
            return EditProposal(id: row["id"]?.intValue ?? 0, videoID: videoID, kind: kind,
                                startTime: row["start_time"]?.doubleValue ?? 0,
                                endTime: row["end_time"]?.doubleValue ?? 0,
                                reason: row["reason"]?.stringValue ?? "", decision: decision)
        }
    }

    func updateEditProposal(_ proposal: EditProposal) throws {
        try connection.execute("UPDATE edit_proposals SET start_time = ?, end_time = ?, decision = ? WHERE id = ?",
                               [.real(proposal.startTime), .real(proposal.endTime),
                                .text(proposal.decision.rawValue), .integer(proposal.id)])
    }

    func replaceTopicRanges(videoID: Int64, topics: [TopicRange]) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM topic_ranges WHERE video_id = ?", [.integer(videoID)])
            for topic in topics {
                let speakersData = try JSONEncoder().encode(topic.speakerKeys)
                let speakers = String(data: speakersData, encoding: .utf8) ?? "[]"
                try connection.execute("""
                    INSERT INTO topic_ranges
                        (video_id, title, start_time, end_time, summary, speaker_keys_json)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, [.integer(videoID), .text(topic.title), .real(topic.startTime),
                          .real(topic.endTime), .text(topic.summary), .text(speakers)])
            }
        }
    }

    func fetchTopicRanges(videoID: Int64) throws -> [TopicRange] {
        try connection.query("SELECT * FROM topic_ranges WHERE video_id = ? ORDER BY start_time", [.integer(videoID)]).map { row in
            let speakers = row["speaker_keys_json"]?.stringValue
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            return TopicRange(id: row["id"]?.intValue ?? 0, videoID: videoID,
                              title: row["title"]?.stringValue ?? "Topic",
                              startTime: row["start_time"]?.doubleValue ?? 0,
                              endTime: row["end_time"]?.doubleValue ?? 0,
                              summary: row["summary"]?.stringValue ?? "", speakerKeys: speakers)
        }
    }

    func upsertAssetMetadata(_ metadata: LibraryAssetMetadata) throws {
        let subjectsData = try JSONEncoder().encode(metadata.subjects)
        let tagsData = try JSONEncoder().encode(metadata.tags)
        try connection.execute("""
            INSERT INTO library_asset_metadata
                (path, kind, is_broll, subjects_json, tags_json, provider, model, display_name, placements_json, technique, analyzed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(path) DO UPDATE SET kind=excluded.kind, is_broll=excluded.is_broll,
                subjects_json=excluded.subjects_json, tags_json=excluded.tags_json,
                display_name=excluded.display_name, placements_json=excluded.placements_json,
                provider=excluded.provider, model=excluded.model, technique=excluded.technique, analyzed_at=datetime('now')
            """, [.text(metadata.path), .text(metadata.kind), .integer(metadata.isBRoll ? 1 : 0),
                  .text(String(data: subjectsData, encoding: .utf8) ?? "[]"),
                  .text(String(data: tagsData, encoding: .utf8) ?? "[]"),
                  metadata.provider.map(SQLValue.text) ?? .null,
                  metadata.model.map(SQLValue.text) ?? .null,
                  metadata.displayName.map(SQLValue.text) ?? .null,
                  try metadata.placements.map { SQLValue.text(String(decoding: try JSONEncoder().encode($0), as: UTF8.self)) } ?? .null,
                  metadata.technique.map(SQLValue.text) ?? .null])
    }

    func fetchAssetMetadata(kind: String? = nil) throws -> [LibraryAssetMetadata] {
        let rows = if let kind {
            try connection.query("SELECT * FROM library_asset_metadata WHERE kind = ? ORDER BY path", [.text(kind)])
        } else {
            try connection.query("SELECT * FROM library_asset_metadata ORDER BY path")
        }
        return rows.map { row in
            func strings(_ column: String) -> [String] {
                row[column]?.stringValue.flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            }
            return LibraryAssetMetadata(path: row["path"]?.stringValue ?? "",
                                        kind: row["kind"]?.stringValue ?? "",
                                        isBRoll: row["is_broll"]?.boolValue ?? false,
                                        subjects: strings("subjects_json"), tags: strings("tags_json"),
                                        provider: row["provider"]?.stringValue,
                                        model: row["model"]?.stringValue,
                                        technique: row["technique"]?.stringValue, displayName: row["display_name"]?.stringValue,
                                        placements: row["placements_json"]?.stringValue == nil ? nil : strings("placements_json"))
        }
    }

    func bumpers() async throws -> [BumperAsset] {
        let metadata = Dictionary(uniqueKeysWithValues: try fetchAssetMetadata(kind: AssetKind.bumpers.rawValue).map { ($0.path, $0) })
        var result: [BumperAsset] = []
        for file in AssetStore.allFiles(of: .bumpers) {
            let info = metadata[file.url.path]
            let name = info?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(BumperAsset(path: file.url.path,
                displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? file.url.deletingPathExtension().lastPathComponent,
                placements: Set((info?.placements ?? BumperPlacement.allCases.map(\.rawValue)).compactMap(BumperPlacement.init(rawValue:))),
                duration: await BumperDurationCache.shared.duration(of: file.url)))
        }
        return result.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func moveBumperMetadata(from source: URL, to destination: URL) throws {
        guard source != destination else { return }
        let old = source.path
        for var row in try fetchAssetMetadata(kind: AssetKind.bumpers.rawValue)
        where row.path == old || row.path.hasPrefix(old + "/") {
            let previous = row.path
            row.path = destination.path + String(previous.dropFirst(old.count))
            try upsertAssetMetadata(row)
            try connection.execute("DELETE FROM library_asset_metadata WHERE path = ?", [.text(previous)])
        }
        AssetCatalogChanges.publish()
    }

    func saveBumper(path: String, displayName: String, placements: Set<BumperPlacement>) throws {
        var metadata = try fetchAssetMetadata(kind: AssetKind.bumpers.rawValue).first { $0.path == path }
            ?? LibraryAssetMetadata(path: path, kind: AssetKind.bumpers.rawValue, isBRoll: false,
                                    subjects: [], tags: [], provider: nil, model: nil)
        metadata.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.placements = placements.map(\.rawValue).sorted()
        try upsertAssetMetadata(metadata)
        AssetCatalogChanges.publish()
    }
}
