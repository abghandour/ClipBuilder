import Foundation

extension Database {
    nonisolated static let dubTakesSchema = """
    CREATE TABLE IF NOT EXISTS dub_takes (
        id TEXT PRIMARY KEY NOT NULL,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        transcription_key TEXT NOT NULL,
        row_start REAL NOT NULL, row_end REAL NOT NULL, language TEXT NOT NULL,
        speaker_key TEXT NOT NULL, text TEXT NOT NULL, voice TEXT NOT NULL,
        model TEXT NOT NULL, settings_hash TEXT NOT NULL,
        audio_file TEXT NOT NULL, alignment_json TEXT, edited INTEGER NOT NULL DEFAULT 0, drive_file_id TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        UNIQUE(video_id, transcription_key, row_start, row_end, language, voice, model, settings_hash)
    );
    CREATE TABLE IF NOT EXISTS dub_speaker_overrides (
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        transcription_key TEXT NOT NULL, row_start REAL NOT NULL, row_end REAL NOT NULL,
        language TEXT NOT NULL, speaker_key TEXT NOT NULL, updated_at TEXT NOT NULL,
        PRIMARY KEY(video_id, transcription_key, row_start, row_end, language)
    );
    """

    /// A durable profile folder beside its library, independent of the disposable cache.
    var dubTakesDirectory: URL {
        path.deletingPathExtension().appendingPathComponent("dub-takes", isDirectory: true)
    }

    func dubVideoHash(_ id: Int64) throws -> String {
        guard let hash = try connection.query("SELECT hash FROM videos WHERE id = ? AND hidden = 0", [.integer(id)])
            .first?["hash"]?.stringValue else { throw ScriptError.invalid("The dub source was removed from this profile.") }
        return hash
    }

    func fetchDubTakes(videoID: Int64) throws -> [DubTake] {
        try connection.query("SELECT * FROM dub_takes WHERE video_id = ? ORDER BY updated_at DESC, rowid DESC",
                             [.integer(videoID)]).map { row in
            DubTake(id: row["id"]?.stringValue ?? "",
                source: DubTakeSource(videoID: videoID, transcriptionKey: row["transcription_key"]?.stringValue ?? "",
                    rowStart: row["row_start"]?.doubleValue ?? 0, rowEnd: row["row_end"]?.doubleValue ?? 0,
                    language: row["language"]?.stringValue ?? "", text: row["text"]?.stringValue ?? ""),
                speakerKey: row["speaker_key"]?.stringValue ?? "unknown", text: row["text"]?.stringValue ?? "",
                voice: row["voice"]?.stringValue ?? "", model: row["model"]?.stringValue ?? "",
                settingsHash: row["settings_hash"]?.stringValue ?? "", audioFile: row["audio_file"]?.stringValue ?? "",
                alignment: row["alignment_json"]?.stringValue.flatMap { try? JSONDecoder().decode(DubTakeAlignment.self, from: Data($0.utf8)) },
                edited: row["edited"]?.intValue == 1, driveFileID: row["drive_file_id"]?.stringValue)
        }
    }

    func upsertDubTake(_ take: DubTake) throws {
        guard !take.audioFile.isEmpty, take.audioFile == URL(fileURLWithPath: take.audioFile).lastPathComponent else {
            throw ScriptError.invalid("A dub take must reference an audio leaf name.")
        }
        _ = try dubVideoHash(take.source.videoID) // Do not resurrect a source removed during a request.
        let alignment = try take.alignment.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let now = Date().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
        try connection.execute("""
            INSERT INTO dub_takes (id, video_id, transcription_key, row_start, row_end, language, speaker_key,
                text, voice, model, settings_hash, audio_file, alignment_json, edited, created_at, updated_at, drive_file_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET speaker_key=excluded.speaker_key, text=excluded.text,
                audio_file=excluded.audio_file, alignment_json=excluded.alignment_json, drive_file_id=excluded.drive_file_id,
                edited=MAX(dub_takes.edited, excluded.edited), updated_at=excluded.updated_at
            """, [.text(take.id), .integer(take.source.videoID), .text(take.source.transcriptionKey),
                  .real(take.source.rowStart), .real(take.source.rowEnd), .text(take.source.language),
                  .text(take.speakerKey), .text(take.text), .text(take.voice), .text(take.model),
                  .text(take.settingsHash), .text(take.audioFile), alignment.map(SQLValue.text) ?? .null,
                  .integer(take.edited ? 1 : 0), .text(now), .text(now), take.driveFileID.map(SQLValue.text) ?? .null])
    }

    /// Publish only if this is still the uploaded version, never resurrect a
    /// take removed with its video or overwrite an edit made during transfer.
    func setDubTakeDriveFile(_ id: String, for take: DubTake) throws {
        guard let current = try fetchDubTakes(videoID: take.source.videoID).first(where: { $0.id == take.id }),
              current.text == take.text, current.audioFile == take.audioFile,
              current.alignment == take.alignment, current.driveFileID == nil else { return }
        try connection.execute("""
            UPDATE dub_takes SET drive_file_id = ?, updated_at = ?
            WHERE id = ? AND drive_file_id IS NULL
            """, [.text(id), .text(Date().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))),
                  .text(take.id)])
    }

    func dubSpeakerOverride(_ source: DubTakeSource) throws -> String? {
        try connection.query("""
            SELECT speaker_key FROM dub_speaker_overrides WHERE video_id = ? AND transcription_key = ?
                AND row_start = ? AND row_end = ? AND language = ?
            """, sourceBindings(source)).first?["speaker_key"]?.stringValue
    }

    func rememberDubReview(_ lines: [DubLine]) throws {
        try connection.transaction {
            for line in lines {
                guard let source = line.takeSource else { continue }
                let textChanged = line.plannedText.map { DubTakeCutter.normalized($0) != DubTakeCutter.normalized(line.text) } ?? false
                let speakerChanged = line.plannedSpeaker.map { $0 != line.speakerKey } ?? false
                guard textChanged || speakerChanged else { continue }
                if let id = line.takeID {
                    try connection.execute("UPDATE dub_takes SET edited = 1, speaker_key = ?, updated_at = ? WHERE id = ?",
                        [.text(line.speakerKey), .text(Date().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))), .text(id)])
                }
                if speakerChanged {
                    try connection.execute("""
                        INSERT INTO dub_speaker_overrides (video_id, transcription_key, row_start, row_end, language, speaker_key, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(video_id, transcription_key, row_start, row_end, language)
                        DO UPDATE SET speaker_key=excluded.speaker_key, updated_at=excluded.updated_at
                        """, sourceBindings(source) + [.text(line.speakerKey), .text(Date().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true)))])
                }
            }
        }
    }

    private func sourceBindings(_ source: DubTakeSource) -> [SQLValue] {
        [.integer(source.videoID), .text(source.transcriptionKey), .real(source.rowStart),
         .real(source.rowEnd), .text(source.language)]
    }

    func dubTakeAudioFiles(videoIDs: [Int64]) throws -> [String] {
        try videoIDs.flatMap { id in
            try connection.query("SELECT audio_file FROM dub_takes WHERE video_id = ?", [.integer(id)])
                .compactMap { $0["audio_file"]?.stringValue }
        }
    }

    func deleteDubTakes(videoIDs: [Int64]) throws {
        for id in videoIDs {
            try connection.execute("DELETE FROM dub_takes WHERE video_id = ?", [.integer(id)])
            try connection.execute("DELETE FROM dub_speaker_overrides WHERE video_id = ?", [.integer(id)])
        }
    }

    func deleteDubTakeAudioFiles(_ names: [String]) throws {
        for name in Set(names) where name == URL(fileURLWithPath: name).lastPathComponent {
            let url = dubTakesDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}
