import Foundation

extension Database {
    // MARK: - Videos

    @discardableResult
    func registerVideo(hash: String, filename: String, path: String, duration: Double,
                       width: Int, height: Int, wide: Bool) async throws -> Int64 {
        let existing = try connection.query("SELECT discovered_at FROM videos WHERE hash = ?", [.text(hash)]).first
        let discovered = existing?["discovered_at"]?.stringValue ?? Date().ISO8601Format()
        let created = await creationDates.resolve(path: path, discoveredAt: discovered)
        let rows = try connection.query("""
            INSERT INTO videos (hash, filename, path, duration, width, height, wide, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(hash) DO UPDATE SET
                filename=excluded.filename,
                path=excluded.path,
                duration=excluded.duration,
                width=excluded.width,
                height=excluded.height,
                wide=excluded.wide,
                created_at=COALESCE(videos.created_at, excluded.created_at)
            RETURNING id
            """, [.text(hash), .text(filename), .text(path), .real(duration),
                  .integer(Int64(width)), .integer(Int64(height)), .integer(wide ? 1 : 0), .text(created)])
        return rows.first?["id"]?.intValue ?? connection.lastInsertRowID
    }

    /// Remove source rows outright; every dependent table cascades.
    func deleteVideos(_ ids: [Int64]) throws {
        for id in ids {
            try connection.execute("DELETE FROM videos WHERE id = ?", [.integer(id)])
        }
    }

    // MARK: - Video notes (timestamped analysis guidance)

    func videoNotes(videoID: Int64) throws -> [VideoNote] {
        try connection.query("SELECT * FROM video_notes WHERE video_id = ? ORDER BY at_time",
                             [.integer(videoID)]).map { row in
            VideoNote(id: row["id"]?.intValue ?? 0,
                      videoID: videoID,
                      atTime: row["at_time"]?.doubleValue ?? 0,
                      note: row["note"]?.stringValue ?? "",
                      provider: row["provider"]?.stringValue,
                      model: row["model"]?.stringValue)
        }
    }

    /// `provenance` marks an AI-written note (a saved soundbite); nil = the
    /// user typed it.
    func addVideoNote(videoID: Int64, at atTime: Double, note: String,
                      provenance: AIProvenance? = nil) throws {
        try connection.execute("""
            INSERT INTO video_notes (video_id, at_time, note, provider, model) VALUES (?, ?, ?, ?, ?)
            """, [.integer(videoID), .real(atTime), .text(note),
                  provenance.map { SQLValue.text($0.provider) } ?? .null,
                  provenance?.model.map(SQLValue.text) ?? .null])
    }

    func deleteVideoNote(id: Int64) throws {
        try connection.execute("DELETE FROM video_notes WHERE id = ?", [.integer(id)])
    }

    // MARK: - Fight outcomes

    func saveFightOutcome(videoID: Int64, runID: Int64, method: String,
                          winnerKey: String?, loserKey: String?, event: String?,
                          round: Int?) throws {
        try connection.execute("""
            INSERT INTO fight_outcomes (video_id, run_id, method, winner_key, loser_key, event, round)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [.integer(videoID), .integer(runID), .text(method),
                  winnerKey.map(SQLValue.text) ?? .null,
                  loserKey.map(SQLValue.text) ?? .null,
                  event.map(SQLValue.text) ?? .null,
                  round.map { SQLValue.integer(Int64($0)) } ?? .null])
    }

    /// Latest outcome per video (newer runs win), optionally scoped to runs.
    func fetchOutcomes(runIDs: Set<Int64> = []) throws -> [FightOutcome] {
        let rows = try connection.query(
            "SELECT * FROM fight_outcomes ORDER BY video_id, id DESC")
        var seenVideos = Set<Int64>()
        var outcomes: [FightOutcome] = []
        for row in rows {
            let runID = row["run_id"]?.intValue ?? 0
            if !runIDs.isEmpty && !runIDs.contains(runID) { continue }
            let videoID = row["video_id"]?.intValue ?? 0
            guard seenVideos.insert(videoID).inserted else { continue }
            outcomes.append(FightOutcome(id: row["id"]?.intValue ?? 0,
                                         videoID: videoID,
                                         runID: runID,
                                         method: row["method"]?.stringValue ?? "",
                                         winnerKey: row["winner_key"]?.stringValue,
                                         loserKey: row["loser_key"]?.stringValue,
                                         event: row["event"]?.stringValue,
                                         round: row["round"]?.intValue.map(Int.init)))
        }
        return outcomes
    }

    // MARK: - Person markers (user-drawn identity boxes)

    func personMarkers(videoID: Int64) throws -> [PersonMarker] {
        try connection.query("SELECT * FROM person_markers WHERE video_id = ? ORDER BY at_time, id",
                             [.integer(videoID)]).map { row in
            PersonMarker(id: row["id"]?.intValue ?? 0,
                         videoID: videoID,
                         atTime: row["at_time"]?.doubleValue ?? 0,
                         x: row["x"]?.doubleValue ?? 0,
                         y: row["y"]?.doubleValue ?? 0,
                         width: row["width"]?.doubleValue ?? 0,
                         height: row["height"]?.doubleValue ?? 0,
                         personID: row["person_id"]?.intValue,
                         ignored: row["ignored"]?.boolValue ?? false)
        }
    }

    func addPersonMarker(videoID: Int64, at atTime: Double,
                         x: Double, y: Double, width: Double, height: Double) throws {
        try connection.execute("""
            INSERT INTO person_markers (video_id, at_time, x, y, width, height)
            VALUES (?, ?, ?, ?, ?, ?)
            """, [.integer(videoID), .real(atTime), .real(x), .real(y), .real(width), .real(height)])
    }

    func updatePersonMarker(_ marker: PersonMarker) throws {
        try connection.execute("""
            UPDATE person_markers SET at_time = ?, x = ?, y = ?, width = ?, height = ?, person_id = ?,
                ignored = ?
            WHERE id = ?
            """, [.real(marker.atTime), .real(marker.x), .real(marker.y),
                  .real(marker.width), .real(marker.height),
                  marker.personID.map(SQLValue.integer) ?? .null,
                  .integer(marker.ignored ? 1 : 0), .integer(marker.id)])
    }

    func deletePersonMarker(id: Int64) throws {
        try connection.execute("DELETE FROM person_markers WHERE id = ?", [.integer(id)])
    }

    // MARK: - Video people (people-only pass roster)

    func fetchVideoPeopleRanges(videoID: Int64) throws -> [VideoPersonRanges] {
        try connection.query("""
            SELECT p.key, p.name, vp.ranges_json
            FROM video_people vp JOIN people p ON p.id = vp.person_id
            WHERE vp.video_id = ? ORDER BY p.key
            """, [.integer(videoID)]).map { row in
            // Corrupt evidence must not silently become whole-video presence.
            let ranges = try row["ranges_json"]?.stringValue.map {
                try JSONDecoder().decode([ScriptTimeRange].self, from: Data($0.utf8))
            } ?? []
            return VideoPersonRanges(key: row["key"]?.stringValue ?? "",
                                     name: row["name"]?.stringValue ?? "", ranges: ranges)
        }
    }

    func fetchVideoPeople(videoID: Int64) throws -> [VideoPersonRecord] {
        try connection.query("""
            SELECT vp.*, p.key AS person_key, p.name AS person_name,
                   p.descriptor AS person_descriptor
            FROM video_people vp JOIN people p ON p.id = vp.person_id
            WHERE vp.video_id = ? ORDER BY vp.portrait_at, p.key
            """, [.integer(videoID)]).map { row in
            let box = row["portrait_json"]?.stringValue
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(VideoPersonRecord.PortraitBox.self, from: $0) }
            return VideoPersonRecord(videoID: videoID,
                                     personID: row["person_id"]?.intValue ?? 0,
                                     key: row["person_key"]?.stringValue ?? "",
                                     name: row["person_name"]?.stringValue ?? "",
                                     descriptor: row["person_descriptor"]?.stringValue ?? "",
                                     portraitAt: row["portrait_at"]?.doubleValue ?? 0,
                                     portraitBox: box)
        }
    }

    /// Replace the video's roster with a fresh people-pass result and stamp
    /// the video as people-detected (the tag-detection gate), recording
    /// which model did the detecting.
    func replaceVideoPeople(videoID: Int64,
                            entries: [(personID: Int64, portraitAt: Double,
                                       portraitJSON: String?, rangesJSON: String?)],
                            provenance: AIProvenance? = nil) throws {
        try connection.transaction {
            try connection.execute("""
                UPDATE videos SET people_detected_at = datetime('now'),
                    people_provider = COALESCE(?, people_provider),
                    people_model = COALESCE(?, people_model),
                    people_seconds = COALESCE(?, people_seconds)
                WHERE id = ?
                """, [provenance.map { SQLValue.text($0.provider) } ?? .null,
                      provenance?.model.map(SQLValue.text) ?? .null,
                      provenance?.duration.map(SQLValue.real) ?? .null,
                      .integer(videoID)])
            try connection.execute("DELETE FROM video_people WHERE video_id = ?",
                                   [.integer(videoID)])
            for entry in entries {
                try connection.execute("""
                    INSERT OR REPLACE INTO video_people
                        (video_id, person_id, portrait_at, portrait_json, ranges_json)
                    VALUES (?, ?, ?, ?, ?)
                    """, [.integer(videoID), .integer(entry.personID), .real(entry.portraitAt),
                          entry.portraitJSON.map(SQLValue.text) ?? .null,
                          entry.rangesJSON.map(SQLValue.text) ?? .null])
            }
        }
    }

    // MARK: - Taste studies (which reels taught the taste profile)

    /// media id → category key of the study that learned from it.
    func tasteStudies() throws -> [Int64: String] {
        var result: [Int64: String] = [:]
        for row in try connection.query("SELECT media_id, category_key FROM taste_studies") {
            if let id = row["media_id"]?.intValue {
                result[id] = row["category_key"]?.stringValue ?? "general"
            }
        }
        return result
    }

    func recordTasteStudy(mediaID: Int64, categoryKey: String) throws {
        try connection.execute("""
            INSERT OR REPLACE INTO taste_studies (media_id, category_key) VALUES (?, ?)
            """, [.integer(mediaID), .text(categoryKey)])
    }

    // MARK: - Center Stage hints (user-framed camera keyframes)

    func centerStageHints(videoID: Int64) throws -> [CameraHint] {
        try connection.query("SELECT * FROM center_stage_hints WHERE video_id = ? ORDER BY at_time, id",
                             [.integer(videoID)]).map { row in
            CameraHint(id: row["id"]?.intValue ?? 0,
                       videoID: videoID,
                       atTime: row["at_time"]?.doubleValue ?? 0,
                       x: row["x"]?.doubleValue ?? 0,
                       y: row["y"]?.doubleValue ?? 0,
                       width: row["width"]?.doubleValue ?? 0,
                       height: row["height"]?.doubleValue ?? 0)
        }
    }

    func addCenterStageHint(videoID: Int64, at atTime: Double,
                            x: Double, y: Double, width: Double, height: Double) throws {
        try connection.execute("""
            INSERT INTO center_stage_hints (video_id, at_time, x, y, width, height)
            VALUES (?, ?, ?, ?, ?, ?)
            """, [.integer(videoID), .real(atTime), .real(x), .real(y), .real(width), .real(height)])
    }

    func updateCenterStageHint(_ hint: CameraHint) throws {
        try connection.execute("""
            UPDATE center_stage_hints SET at_time = ?, x = ?, y = ?, width = ?, height = ?
            WHERE id = ?
            """, [.real(hint.atTime), .real(hint.x), .real(hint.y),
                  .real(hint.width), .real(hint.height), .integer(hint.id)])
    }

    func deleteCenterStageHint(id: Int64) throws {
        try connection.execute("DELETE FROM center_stage_hints WHERE id = ?", [.integer(id)])
    }

    /// Scene ids + ranges of one analyze batch — the portrait-fit pass input.
    func sceneRanges(runID: Int64) throws -> [(id: Int64, start: Double, end: Double)] {
        try connection.query("SELECT id, start_time, end_time FROM scenes WHERE run_id = ?",
                             [.integer(runID)]).map { row in
            (row["id"]?.intValue ?? 0,
             row["start_time"]?.doubleValue ?? 0,
             row["end_time"]?.doubleValue ?? 0)
        }
    }

    func addSceneTag(sceneID: Int64, tag: String) throws {
        try connection.execute("INSERT OR IGNORE INTO scene_tags (scene_id, tag) VALUES (?, ?)",
                               [.integer(sceneID), .text(tag)])
    }

    /// Drop every tag of one scene sharing a prefix — a re-run of a pass
    /// that owns that tag family (e.g. "framed:") starts from a clean slate.
    func removeSceneTags(sceneID: Int64, withPrefix prefix: String) throws {
        try connection.execute("DELETE FROM scene_tags WHERE scene_id = ? AND tag LIKE ?",
                               [.integer(sceneID), .text(prefix + "%")])
    }

    /// The person's first user-drawn marker with its video path — the best
    /// possible avatar source, since the box is ground truth for who's in it.
    func markerReference(personID: Int64) throws -> (videoPath: String, marker: PersonMarker)? {
        try connection.query("""
            SELECT pm.*, v.path AS video_path FROM person_markers pm
            JOIN videos v ON v.id = pm.video_id
            WHERE pm.person_id = ? ORDER BY pm.id LIMIT 1
            """, [.integer(personID)]).first.map { row in
            (row["video_path"]?.stringValue ?? "",
             PersonMarker(id: row["id"]?.intValue ?? 0,
                          videoID: row["video_id"]?.intValue ?? 0,
                          atTime: row["at_time"]?.doubleValue ?? 0,
                          x: row["x"]?.doubleValue ?? 0,
                          y: row["y"]?.doubleValue ?? 0,
                          width: row["width"]?.doubleValue ?? 0,
                          height: row["height"]?.doubleValue ?? 0,
                          personID: personID))
        }
    }

    /// Rename support: the file was already moved on disk; scenes join the
    /// videos table, so their paths follow automatically. `provenance` is
    /// the model that proposed the name; nil (a hand rename) clears it.
    func renameVideo(id: Int64, filename: String, path: String,
                     provenance: AIProvenance? = nil) throws {
        try connection.execute("""
            UPDATE videos SET filename = ?, path = ?, naming_provider = ?, naming_model = ? WHERE id = ?
            """, [.text(filename), .text(path),
                  provenance.map { SQLValue.text($0.provider) } ?? .null,
                  provenance?.model.map(SQLValue.text) ?? .null,
                  .integer(id)])
    }

    /// Resolve only missing dates once per open, off the main actor. Each saved
    /// value makes the backfill restartable if the app closes partway through.
    func backfillCreatedDates() async throws {
        guard !createdDatesBackfilled else { return }
        let rows = try connection.query("SELECT id, path, discovered_at FROM videos WHERE created_at IS NULL")
        for row in rows {
            let date = await creationDates.resolve(path: row["path"]?.stringValue ?? "",
                                                  discoveredAt: row["discovered_at"]?.stringValue)
            try connection.execute("UPDATE videos SET created_at = ? WHERE id = ? AND created_at IS NULL",
                                   [.text(date), .integer(row["id"]?.intValue ?? 0)])
        }
        createdDatesBackfilled = true
    }

    func fetchVideos(projectID: Int64? = nil) async throws -> [VideoRecord] {
        try await backfillCreatedDates()
        let projectID = try scopedProjectID(projectID)
        if let projectID {
            return try connection.query("""
                SELECT v.* FROM videos v
                JOIN project_videos pv ON pv.video_id = v.id
                WHERE pv.project_id = ?
                ORDER BY v.filename COLLATE NOCASE
                """, [.integer(projectID)]).map(Self.videoRecord)
        }
        return try connection.query("SELECT * FROM videos ORDER BY filename COLLATE NOCASE")
            .map(Self.videoRecord)
    }

    func video(id: Int64) throws -> VideoRecord? {
        try connection.query("SELECT * FROM videos WHERE id = ?", [.integer(id)]).first.map(Self.videoRecord)
    }

    static func videoRecord(_ row: SQLRow) -> VideoRecord {
        VideoRecord(
            id: row["id"]?.intValue ?? 0,
            hash: row["hash"]?.stringValue ?? "",
            filename: row["filename"]?.stringValue ?? "",
            path: row["path"]?.stringValue ?? "",
            duration: row["duration"]?.doubleValue ?? 0,
            width: Int(row["width"]?.intValue ?? 0),
            height: Int(row["height"]?.intValue ?? 0),
            wide: row["wide"]?.boolValue ?? false,
            discoveredAt: row["discovered_at"]?.stringValue,
            createdAt: row["created_at"]?.stringValue,
            analyzedAt: row["analyzed_at"]?.stringValue,
            visualAnalyzedAt: row["visual_analyzed_at"]?.stringValue,
            speechAnalyzedAt: row["speech_analyzed_at"]?.stringValue,
            visualAnalyzerProvider: row["visual_analyzer_provider"]?.stringValue,
            visualAnalyzerModel: row["visual_analyzer_model"]?.stringValue,
            speechAnalyzerProvider: row["speech_analyzer_provider"]?.stringValue,
            speechAnalyzerModel: row["speech_analyzer_model"]?.stringValue,
            peopleDetectedAt: row["people_detected_at"]?.stringValue,
            peopleProvider: row["people_provider"]?.stringValue,
            peopleModel: row["people_model"]?.stringValue,
            peopleSeconds: row["people_seconds"]?.doubleValue,
            speechSeconds: row["speech_seconds"]?.doubleValue,
            namingProvider: row["naming_provider"]?.stringValue,
            namingModel: row["naming_model"]?.stringValue,
            videoType: row["video_type"]?.stringValue,
            podcastLayout: row["podcast_layout"]?.stringValue,
            podcastSeamX: row["podcast_seam_x"]?.doubleValue,
            podcastLayoutConfidence: row["podcast_layout_confidence"]?.doubleValue,
            podcastTilesJSON: row["podcast_tiles_json"]?.stringValue,
            driveFileID: row["drive_file_id"]?.stringValue,
            driveLink: row["drive_link"]?.stringValue,
            driveOffloaded: row["drive_offloaded"]?.boolValue ?? false,
            driveShared: row["drive_shared"]?.boolValue ?? false)
    }

    func setVideoType(id: Int64, type: String?) throws {
        try connection.execute("UPDATE videos SET video_type = ? WHERE id = ?",
                               [type.map(SQLValue.text) ?? .null, .integer(id)])
    }

    func setPodcastLayout(videoID: Int64, layout: PodcastLayout,
                          seamX: Double?, confidence: Double, tiles: [PodcastTile] = []) throws {
        let tilesJSON = tiles.isEmpty ? nil
            : (try? JSONEncoder().encode(tiles)).flatMap { String(data: $0, encoding: .utf8) }
        try connection.execute("""
            UPDATE videos SET podcast_layout = ?, podcast_seam_x = ?, podcast_layout_confidence = ?,
                podcast_tiles_json = ?
            WHERE id = ?
            """, [.text(layout.rawValue), seamX.map(SQLValue.real) ?? .null,
                  .real(confidence), tilesJSON.map(SQLValue.text) ?? .null, .integer(videoID)])
    }

    func replaceSpeakerTurns(videoID: Int64, turns: [SpeakerTurn]) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM speaker_turns WHERE video_id = ?", [.integer(videoID)])
            for turn in turns {
                try connection.execute("""
                    INSERT INTO speaker_turns
                        (video_id, start_time, end_time, cluster, confidence, picture_side,
                         picture_confidence, resolved_side, person_key, tile)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(videoID), .real(turn.start), .real(turn.end),
                          .integer(Int64(turn.cluster)), .real(turn.confidence),
                          .text(turn.pictureSide.rawValue), .real(turn.pictureConfidence),
                          .text(turn.resolvedSide.rawValue),
                          turn.personKey.map(SQLValue.text) ?? .null,
                          turn.tile.map { SQLValue.integer(Int64($0)) } ?? .null])
            }
        }
    }

    // MARK: - Voice profiles (what each file taught about a person's voice)

    /// Replace what this video remembers about its people's voices.
    func replaceVoiceProfiles(videoID: Int64, profiles: [VoiceProfile]) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM voice_profiles WHERE video_id = ?", [.integer(videoID)])
            for profile in profiles where profile.videoID == videoID {
                let json = String(decoding: try JSONEncoder().encode(profile.vector), as: UTF8.self)
                try connection.execute("""
                    INSERT INTO voice_profiles (person_key, video_id, vector_json, windows, correction_windows)
                    VALUES (?, ?, ?, ?, ?)
                    """, [.text(profile.personKey), .integer(videoID), .text(json),
                          .integer(Int64(profile.windows)), .integer(Int64(profile.correctionWindows))])
            }
        }
    }

    /// Every stored voice profile, leaving out one video's own so a re-map
    /// of that video is not seeded with itself.
    func fetchVoiceProfiles(excludingVideoID excluded: Int64? = nil) throws -> [VoiceProfile] {
        try connection.query("""
            SELECT person_key, video_id, vector_json, windows, correction_windows
            FROM voice_profiles WHERE video_id != ? ORDER BY person_key, video_id
            """, [.integer(excluded ?? -1)]).compactMap { row in
                guard let key = row["person_key"]?.stringValue, let videoID = row["video_id"]?.intValue,
                      let data = row["vector_json"]?.stringValue?.data(using: .utf8),
                      let vector = try? JSONDecoder().decode([Double].self, from: data) else { return nil }
                return VoiceProfile(personKey: key, videoID: videoID, vector: vector,
                                    windows: Int(row["windows"]?.intValue ?? 0),
                                    correctionWindows: Int(row["correction_windows"]?.intValue ?? 0))
            }
    }

    func fetchSpeakerTurns(videoID: Int64) throws -> [SpeakerTurn] {
        try connection.query("""
            SELECT * FROM speaker_turns WHERE video_id = ? ORDER BY start_time, id
            """, [.integer(videoID)]).map { row in
                SpeakerTurn(id: row["id"]?.intValue ?? 0,
                            videoID: videoID,
                            start: row["start_time"]?.doubleValue ?? 0,
                            end: row["end_time"]?.doubleValue ?? 0,
                            cluster: Int(row["cluster"]?.intValue ?? 0),
                            confidence: row["confidence"]?.doubleValue ?? 0,
                            pictureSide: PodcastSpeakerSide(rawValue: row["picture_side"]?.stringValue ?? "") ?? .unknown,
                            pictureConfidence: row["picture_confidence"]?.doubleValue ?? 0,
                            resolvedSide: PodcastSpeakerSide(rawValue: row["resolved_side"]?.stringValue ?? "") ?? .unknown,
                            personKey: row["person_key"]?.stringValue,
                            tile: row["tile"]?.intValue.map { Int($0) })
            }
    }
}
