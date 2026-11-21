import Foundation

/// One voice-over recording made over an Express reel (docs/Express-Voice-Over-Plan.md).
/// It is anchored to the picture that was under it, `(videoID, sourceTime)`,
/// so it follows that footage when the reel changes; `reelTime` is where it
/// sat in the rough cut it was recorded over.
nonisolated struct VoiceTake: Identifiable, Sendable, Equatable {
    enum TranscriptState: String, Sendable { case pending, done, empty, failed }

    var id: String
    var projectID: Int64
    var videoID: Int64
    /// Seconds in the source recording where the voice starts.
    var sourceTime: Double
    /// Seconds into a pause on contact at which the voice starts, when it was
    /// recorded over the held frame: every second of a hold shows the same
    /// source second, so the anchor alone cannot tell them apart.
    var holdOffset: Double? = nil
    /// Which showing of that picture it was recorded over (0 = the first),
    /// when the same footage is in the reel more than once. It does not
    /// depend on either reel's clock. Nil on recordings made before it existed.
    var occurrence: Int? = nil
    /// Seconds in the reel it was recorded over.
    var reelTime: Double
    var duration: Double
    /// Leaf name inside `Database.voiceTakesDirectory`.
    var file: String
    /// Bare language code of the speech ("pt", "en"); empty until transcribed.
    var language = ""
    /// What was said, as the captions show it. The user can correct it.
    var text = ""
    /// Word clocks in seconds from the start of the recording.
    var words: [TranscriptWord] = []
    /// Caption text per bare language code.
    var translations: [String: VoiceTakeTranslation] = [:]
    var state = TranscriptState.pending
    var createdAt = ""

    var end: Double { reelTime + duration }
}

nonisolated struct VoiceTakeTranslation: Codable, Sendable, Hashable {
    var text: String
    /// The user corrected it: a new translation never replaces it.
    var edited: Bool? = nil
}

extension Database {
    /// Local only: not in any `SyncTable` list.
    nonisolated static let voiceTakesSchema = """
    CREATE TABLE IF NOT EXISTS voice_takes (
        id TEXT PRIMARY KEY NOT NULL,
        project_id INTEGER NOT NULL,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        source_time REAL NOT NULL, reel_time REAL NOT NULL, duration REAL NOT NULL,
        audio_file TEXT NOT NULL, language TEXT NOT NULL DEFAULT '', text TEXT NOT NULL DEFAULT '',
        words TEXT, translations TEXT, state TEXT NOT NULL DEFAULT 'pending',
        created_at TEXT NOT NULL,
        hold_offset REAL,
        occurrence INTEGER
    );
    CREATE INDEX IF NOT EXISTS voice_takes_owner ON voice_takes(project_id, video_id);
    """

    /// A durable folder beside the library, like the dub takes.
    nonisolated var voiceTakesDirectory: URL {
        path.deletingPathExtension().appendingPathComponent("voice-takes", isDirectory: true)
    }

    nonisolated func voiceTakeURL(_ take: VoiceTake) -> URL {
        voiceTakesDirectory.appendingPathComponent(take.file)
    }

    private nonisolated static func voiceTake(_ row: SQLRow) -> VoiceTake {
        VoiceTake(id: row["id"]?.stringValue ?? "",
            projectID: row["project_id"]?.intValue ?? 0, videoID: row["video_id"]?.intValue ?? 0,
            sourceTime: row["source_time"]?.doubleValue ?? 0, holdOffset: row["hold_offset"]?.doubleValue,
            occurrence: row["occurrence"]?.intValue.map(Int.init), reelTime: row["reel_time"]?.doubleValue ?? 0,
            duration: row["duration"]?.doubleValue ?? 0, file: row["audio_file"]?.stringValue ?? "",
            language: row["language"]?.stringValue ?? "", text: row["text"]?.stringValue ?? "",
            words: row["words"]?.stringValue
                .flatMap { try? JSONDecoder().decode([TranscriptWord].self, from: Data($0.utf8)) } ?? [],
            translations: row["translations"]?.stringValue
                .flatMap { try? JSONDecoder().decode([String: VoiceTakeTranslation].self, from: Data($0.utf8)) } ?? [:],
            state: VoiceTake.TranscriptState(rawValue: row["state"]?.stringValue ?? "") ?? .pending,
            createdAt: row["created_at"]?.stringValue ?? "")
    }

    /// The recordings of one Express reel, in reel order.
    func fetchVoiceTakes(projectID: Int64, videoIDs: [Int64]) throws -> [VoiceTake] {
        guard !videoIDs.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: videoIDs.count).joined(separator: ",")
        return try connection.query("""
            SELECT * FROM voice_takes WHERE project_id = ? AND video_id IN (\(marks))
            ORDER BY reel_time, created_at
            """, [.integer(projectID)] + videoIDs.map(SQLValue.integer)).map(Self.voiceTake)
    }

    func fetchVoiceTake(id: String) throws -> VoiceTake? {
        try connection.query("SELECT * FROM voice_takes WHERE id = ?", [.text(id)]).first.map(Self.voiceTake)
    }

    /// Inserts the recording, or replaces everything but its identity. Work
    /// that finishes later (transcription, translation, an edit) must use the
    /// conditional updates below, so it never brings back a deleted row.
    func saveVoiceTake(_ take: VoiceTake) throws {
        guard !take.file.isEmpty, take.file == URL(fileURLWithPath: take.file).lastPathComponent else {
            throw ScriptError.invalid("A voice recording must reference an audio leaf name.")
        }
        let words = take.words.isEmpty ? nil : String(decoding: try JSONEncoder().encode(take.words), as: UTF8.self)
        let translations = take.translations.isEmpty ? nil
            : String(decoding: try JSONEncoder().encode(take.translations), as: UTF8.self)
        let created = take.createdAt.isEmpty
            ? Date().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true)) : take.createdAt
        try connection.execute("""
            INSERT INTO voice_takes (id, project_id, video_id, source_time, reel_time, duration, audio_file,
                language, text, words, translations, state, created_at, hold_offset, occurrence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET source_time=excluded.source_time, reel_time=excluded.reel_time,
                hold_offset=excluded.hold_offset, occurrence=excluded.occurrence,
                duration=excluded.duration, audio_file=excluded.audio_file, language=excluded.language,
                text=excluded.text, words=excluded.words, translations=excluded.translations, state=excluded.state
            """, [.text(take.id), .integer(take.projectID), .integer(take.videoID), .real(take.sourceTime),
                  .real(take.reelTime), .real(take.duration), .text(take.file), .text(take.language),
                  .text(take.text), words.map(SQLValue.text) ?? .null, translations.map(SQLValue.text) ?? .null,
                  .text(take.state.rawValue), .text(created), take.holdOffset.map(SQLValue.real) ?? .null,
                  take.occurrence.map { SQLValue.integer(Int64($0)) } ?? .null])
    }

    // Each conditional write below reads the row and writes it inside one
    // `BEGIN IMMEDIATE` transaction. That takes SQLite's write lock first, so
    // no other connection, in this app or in another copy of it on the same
    // library, can delete or change the row between the read and the write.

    /// The user's correction: saved only while the recording still exists.
    @discardableResult
    func updateVoiceTake(_ take: VoiceTake) throws -> Bool {
        try connection.transaction {
            guard try fetchVoiceTake(id: take.id) != nil else { return false }
            try saveVoiceTake(take)
            return true
        }
    }

    /// A correction worked out from the row as it is stored, read and saved
    /// in one step. False when the recording is gone or nothing changed.
    @discardableResult
    func correctVoiceTake(id: String, _ change: @Sendable (VoiceTake) -> VoiceTake) throws -> Bool {
        // Worked out before the write lock is taken (word alignment can be
        // slow), and again under it only if the row changed in between.
        guard let seen = try fetchVoiceTake(id: id) else { return false }
        let prepared = change(seen)
        return try connection.transaction {
            guard let current = try fetchVoiceTake(id: id) else { return false }
            let corrected = current == seen ? prepared : change(current)
            guard corrected != current else { return false }
            try saveVoiceTake(corrected)
            return true
        }
    }

    /// The transcriber's result: kept only while the recording exists and is
    /// still waiting for it, so it never overwrites what the user typed.
    @discardableResult
    func setVoiceTakeTranscript(_ take: VoiceTake) throws -> Bool {
        try connection.transaction {
            guard var current = try fetchVoiceTake(id: take.id), current.state == .pending else { return false }
            current.language = take.language
            current.text = take.text
            current.words = take.words
            current.state = take.state
            try saveVoiceTake(current)
            return true
        }
    }

    /// A translation: kept only while the recording exists, still says what
    /// was translated, and has no caption in that language yet.
    @discardableResult
    func setVoiceTakeTranslation(id: String, language code: String, text: String, of original: String) throws -> Bool {
        try connection.transaction {
            guard var current = try fetchVoiceTake(id: id), current.text == original,
                  current.translations[code] == nil else { return false }
            current.translations[code] = VoiceTakeTranslation(text: text)
            try saveVoiceTake(current)
            return true
        }
    }

    /// False when there was no such row: another copy of the app on this
    /// library deleted it first, and may be keeping its audio for Undo.
    /// Of two copies deleting the same recording at once, exactly one gets true.
    @discardableResult
    func deleteVoiceTake(id: String) throws -> Bool {
        try connection.transaction {
            guard try voiceTakeExists(id: id) else { return false }
            try connection.execute("DELETE FROM voice_takes WHERE id = ?", [.text(id)])
            return true
        }
    }

    /// Undo of a delete: the row is put back only while its audio is still
    /// there. False when the audio is gone. Under the write lock, like
    /// `discardVoiceTakeAudio`, so the two cannot cross.
    func restoreVoiceTake(_ take: VoiceTake) throws -> Bool {
        try connection.transaction {
            guard FileManager.default.fileExists(atPath: voiceTakeURL(take).path) else { return false }
            try saveVoiceTake(take)
            return true
        }
    }

    /// Removes a deleted recording's audio, only while its row is still
    /// gone: another copy of the app may have put the recording back.
    func discardVoiceTakeAudio(_ take: VoiceTake) throws {
        try connection.transaction {
            guard try !voiceTakeExists(id: take.id) else { return }
            try? FileManager.default.removeItem(at: voiceTakeURL(take))
        }
    }

    func voiceTakeExists(id: String) throws -> Bool {
        try !connection.query("SELECT 1 FROM voice_takes WHERE id = ?", [.text(id)]).isEmpty
    }
}
