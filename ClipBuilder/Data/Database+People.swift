import Foundation

nonisolated struct PeopleMergeSnapshot: Sendable {
    var survivor: PersonRecord
    var sources: [SQLRow]
    var videoPeople: [SQLRow]
    var tagFields: [SQLRow]
    var survivorTagFields: [SQLRow]
    var sceneTags: [(sceneID: Int64, tag: String)]
    var survivorSceneTags: [SQLRow]
    var sourceSceneTags: [SQLRow]
    var speakerTurnIDs: [Int64: String]
    var transcriptIDs: [Int64: String]
    var markerIDs: [Int64: Int64]
    var voiceProfiles: [SQLRow]
    var survivorVoiceProfiles: [SQLRow]
}

extension Database {
    // MARK: - People

    /// Profile-wide portrait references, deliberately independent of the active project.
    func podcastPortraitReferences() throws -> [(key: String, path: String, time: Double,
                                                box: VideoPersonRecord.PortraitBox)] {
        var references: [(String, String, Double, VideoPersonRecord.PortraitBox)] = []
        for person in try fetchPeople() {
            if let videoID = person.avatarVideoID, let time = person.avatarTime,
               let box = person.avatarBox,
               let path = try connection.query("SELECT path FROM videos WHERE id = ?", [.integer(videoID)])
                .first?["path"]?.stringValue, FileManager.default.fileExists(atPath: path) {
                references.append((person.key, path, time, box))
            } else if let reference = try markerReference(personID: person.id) {
                let marker = reference.marker
                references.append((person.key, reference.videoPath, marker.atTime,
                                   .init(x: marker.x, y: marker.y, w: marker.width, h: marker.height)))
            } else if let portrait = try rosterPortrait(personID: person.id) {
                references.append((person.key, portrait.videoPath, portrait.time, portrait.box))
            }
        }
        return references
    }

    /// The people pass's portrait of a person: the frame and box its most
    /// recent roster entry was cropped from. The face avatars use it before
    /// guessing from a scene, where a grid of people gives the wrong face.
    func rosterPortrait(personID: Int64) throws -> (videoPath: String, time: Double, box: VideoPersonRecord.PortraitBox)? {
        guard let row = try connection.query("""
            SELECT v.path, vp.portrait_at, vp.portrait_json FROM video_people vp
            JOIN videos v ON v.id = vp.video_id
            WHERE vp.person_id = ? AND vp.portrait_json IS NOT NULL
            ORDER BY vp.video_id DESC LIMIT 1
            """, [.integer(personID)]).first,
            let path = row["path"]?.stringValue, FileManager.default.fileExists(atPath: path),
            let data = row["portrait_json"]?.stringValue?.data(using: .utf8),
            let box = try? JSONDecoder().decode(VideoPersonRecord.PortraitBox.self, from: data)
        else { return nil }
        return (path, row["portrait_at"]?.doubleValue ?? 0, box)
    }

    func fetchPeople() throws -> [PersonRecord] {
        try connection.query("SELECT * FROM people ORDER BY name COLLATE NOCASE, id").map { row in
            PersonRecord(id: row["id"]?.intValue ?? 0,
                         key: row["key"]?.stringValue ?? "",
                         name: row["name"]?.stringValue ?? "",
                         descriptor: row["descriptor"]?.stringValue ?? "",
                         hidden: (row["hidden"]?.intValue ?? 0) != 0,
                         avatarVideoID: row["avatar_video_id"]?.intValue,
                         avatarTime: row["avatar_time"]?.doubleValue,
                         avatarBoxJSON: row["avatar_box"]?.stringValue,
                         category: row["category"]?.stringValue.flatMap(PersonCategory.init(rawValue:)))
        }
    }

    /// File a person under a role (or clear it with nil).
    func setPersonCategory(id: Int64, category: PersonCategory?) throws {
        try connection.execute("UPDATE people SET category = ? WHERE id = ?",
                               [category.map { .text($0.rawValue) } ?? .null, .integer(id)])
    }

    /// Save (or clear, with nils) a person's hand-picked avatar frame.
    func setPersonAvatar(id: Int64, videoID: Int64?, time: Double?, boxJSON: String?) throws {
        try connection.execute("""
            UPDATE people SET avatar_video_id = ?, avatar_time = ?, avatar_box = ? WHERE id = ?
            """, [videoID.map(SQLValue.integer) ?? .null,
                  time.map(SQLValue.real) ?? .null,
                  boxJSON.map(SQLValue.text) ?? .null,
                  .integer(id)])
    }

    /// Tuck a person into (or bring them back from) the People screen's
    /// Hidden bucket. Identity is untouched — detection still reuses their
    /// key and their scene tags stay.
    func setPersonHidden(id: Int64, hidden: Bool) throws {
        try connection.execute("UPDATE people SET hidden = ? WHERE id = ?",
                               [.integer(hidden ? 1 : 0), .integer(id)])
    }

    /// File several people at once (the People Roles wizard's Apply).
    func setPersonCategories(_ assignments: [(id: Int64, category: PersonCategory?)]) throws {
        try connection.transaction {
            for assignment in assignments {
                try connection.execute("UPDATE people SET category = ? WHERE id = ?",
                                       [assignment.category.map { .text($0.rawValue) } ?? .null,
                                        .integer(assignment.id)])
            }
        }
    }

    /// Register a detected person, refreshing the visual descriptor with the
    /// latest sighting (names are user-owned and never touched here).
    func upsertPerson(key: String, descriptor: String) throws {
        try connection.execute("""
            INSERT INTO people (key, descriptor) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET
                descriptor = CASE WHEN excluded.descriptor != '' THEN excluded.descriptor
                                  ELSE people.descriptor END
            """, [.text(key), .text(descriptor)])
    }

    func renamePerson(id: Int64, name: String) throws {
        try connection.execute("UPDATE people SET name = ? WHERE id = ?", [.text(name), .integer(id)])
    }

    /// Remove a person and every scene tag pointing at them.
    func deletePerson(_ person: PersonRecord) throws {
        try connection.transaction {
            try connection.execute("UPDATE speaker_turns SET person_key = NULL WHERE person_key = ?",
                                   [.text(person.key)])
            // Lines attributed to them by hand go back to the automatic label.
            try connection.execute("UPDATE transcripts SET speaker_key = NULL WHERE speaker_key = ?",
                                   [.text(person.key)])
            try connection.execute("DELETE FROM voice_profiles WHERE person_key = ?", [.text(person.key)])
            try connection.execute("DELETE FROM scene_tags WHERE tag = ?", [.text(person.tag)])
            try connection.execute("UPDATE person_markers SET person_id = NULL WHERE person_id = ?",
                                   [.integer(person.id)])
            try connection.execute("DELETE FROM people WHERE id = ?", [.integer(person.id)])
        }
    }

    /// The AI occasionally splits one real person into two keys — merging
    /// retags every scene of `source` onto `target` and drops `source`.
    func mergePeople(source: PersonRecord, into target: PersonRecord) throws {
        guard source.id != target.id else { return }
        try connection.transaction {
            try mergePersonRows(source: source, into: target)
        }
    }

    /// Capture and commit the whole batch on the database actor without suspending.
    /// A failed merge or rename rolls back every source, leaving the previous undo usable.
    func mergePeople(sources: [PersonRecord], into survivor: PersonRecord,
                     renamingTo name: String?) throws -> PeopleMergeSnapshot {
        try connection.transaction {
            let snapshot = try peopleMergeSnapshot(sources: sources, survivor: survivor)
            for source in sources where source.id != survivor.id {
                try mergePersonRows(source: source, into: survivor)
            }
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                try renamePerson(id: survivor.id, name: name)
            }
            return snapshot
        }
    }

    private func mergePersonRows(source: PersonRecord, into target: PersonRecord) throws {
        try connection.execute("""
            INSERT OR IGNORE INTO person_tag_fields (person_key, field, value, provenance, source)
            SELECT ?, field, value, provenance, source FROM person_tag_fields WHERE person_key = ?
            """, [.text(target.key), .text(source.key)])
        try connection.execute("UPDATE speaker_turns SET person_key = ? WHERE person_key = ?",
                               [.text(target.key), .text(source.key)])
        try connection.execute("UPDATE transcripts SET speaker_key = ? WHERE speaker_key = ?",
                               [.text(target.key), .text(source.key)])
        // The target's own voice from a file wins over the source's.
        try connection.execute("UPDATE OR IGNORE voice_profiles SET person_key = ? WHERE person_key = ?",
                               [.text(target.key), .text(source.key)])
        try connection.execute("DELETE FROM voice_profiles WHERE person_key = ?", [.text(source.key)])
        try connection.execute("UPDATE OR IGNORE scene_tags SET tag = ? WHERE tag = ?",
                               [.text(target.tag), .text(source.tag)])
        // Rows whose retag collided with an existing target tag remain.
        try connection.execute("DELETE FROM scene_tags WHERE tag = ?", [.text(source.tag)])
        try connection.execute("UPDATE person_markers SET person_id = ? WHERE person_id = ?",
                               [.integer(target.id), .integer(source.id)])
        for row in try connection.query("SELECT video_id FROM video_people WHERE person_id = ?", [.integer(source.id)]) {
            if let videoID = row["video_id"]?.intValue {
                try mergePeopleRoster(videoID: videoID, from: source, to: target)
            }
        }
        try connection.execute("""
            UPDATE people SET avatar_video_id = source.avatar_video_id,
                avatar_time = source.avatar_time, avatar_box = source.avatar_box
            FROM people AS source
            WHERE people.id = ? AND people.avatar_video_id IS NULL
                AND source.id = ? AND source.avatar_video_id IS NOT NULL
            """, [.integer(target.id), .integer(source.id)])
        try connection.execute("DELETE FROM people WHERE id = ?", [.integer(source.id)])
    }

    func peopleMergeSnapshot(sources: [PersonRecord], survivor: PersonRecord) throws -> PeopleMergeSnapshot {
        guard let survivor = try fetchPeople().first(where: { $0.id == survivor.id }) else {
            throw SQLiteError.step("The merge survivor no longer exists", sql: "SELECT * FROM people")
        }
        var snapshot = PeopleMergeSnapshot(
            survivor: survivor, sources: [],
            videoPeople: try connection.query("SELECT * FROM video_people WHERE person_id = ?", [.integer(survivor.id)]),
            tagFields: [],
            survivorTagFields: try connection.query("SELECT * FROM person_tag_fields WHERE person_key = ?", [.text(survivor.key)]),
            sceneTags: [],
            survivorSceneTags: try connection.query("SELECT * FROM scene_tags WHERE tag = ?", [.text(survivor.tag)]),
            sourceSceneTags: [], speakerTurnIDs: [:], transcriptIDs: [:], markerIDs: [:], voiceProfiles: [],
            survivorVoiceProfiles: try connection.query("SELECT * FROM voice_profiles WHERE person_key = ?", [.text(survivor.key)]))
        var seen: Set<Int64> = [survivor.id]
        for source in sources where seen.insert(source.id).inserted {
            guard let row = try connection.query("SELECT * FROM people WHERE id = ?", [.integer(source.id)]).first else {
                throw SQLiteError.step("A person to merge no longer exists", sql: "SELECT * FROM people")
            }
            snapshot.sources.append(row)
            snapshot.videoPeople += try connection.query("SELECT * FROM video_people WHERE person_id = ?", [.integer(source.id)])
            snapshot.tagFields += try connection.query("SELECT * FROM person_tag_fields WHERE person_key = ?", [.text(source.key)])
            let tags = try connection.query("SELECT * FROM scene_tags WHERE tag = ?", [.text(source.tag)])
            snapshot.sourceSceneTags += tags
            snapshot.sceneTags += tags.compactMap { row in
                guard let sceneID = row["scene_id"]?.intValue else { return nil }
                return (sceneID, source.tag)
            }
            for row in try connection.query("SELECT id FROM speaker_turns WHERE person_key = ?", [.text(source.key)]) {
                if let id = row["id"]?.intValue { snapshot.speakerTurnIDs[id] = source.key }
            }
            for row in try connection.query("SELECT id FROM transcripts WHERE speaker_key = ?", [.text(source.key)]) {
                if let id = row["id"]?.intValue { snapshot.transcriptIDs[id] = source.key }
            }
            for row in try connection.query("SELECT id FROM person_markers WHERE person_id = ?", [.integer(source.id)]) {
                if let id = row["id"]?.intValue { snapshot.markerIDs[id] = source.id }
            }
            snapshot.voiceProfiles += try connection.query("SELECT * FROM voice_profiles WHERE person_key = ?", [.text(source.key)])
        }
        let affectedScenes = Set(snapshot.sceneTags.map(\.sceneID))
        snapshot.survivorSceneTags.removeAll { !affectedScenes.contains($0["scene_id"]?.intValue ?? -1) }
        let affectedVoiceVideos = Set(snapshot.voiceProfiles.compactMap { $0["video_id"]?.intValue })
        snapshot.survivorVoiceProfiles.removeAll { !affectedVoiceVideos.contains($0["video_id"]?.intValue ?? -1) }
        return snapshot
    }

    func restorePeopleMerge(_ snapshot: PeopleMergeSnapshot) throws {
        try connection.transaction {
            let survivor = snapshot.survivor
            // Original sync IDs let insert triggers resurrect the same remote identities.
            for row in snapshot.sources {
                // An ID reused since the merge must fail atomically, not delete a new person.
                try restorePeopleMergeRow(row, table: "people", replacing: false)
            }
            try renamePerson(id: survivor.id, name: survivor.name)
            try setPersonCategory(id: survivor.id, category: survivor.category)
            try setPersonHidden(id: survivor.id, hidden: survivor.hidden)
            try setPersonAvatar(id: survivor.id, videoID: survivor.avatarVideoID,
                                time: survivor.avatarTime, boxJSON: survivor.avatarBoxJSON)

            for videoID in Set(snapshot.videoPeople.compactMap { $0["video_id"]?.intValue }) {
                try connection.execute("DELETE FROM video_people WHERE person_id = ? AND video_id = ?",
                                       [.integer(survivor.id), .integer(videoID)])
            }
            for row in snapshot.videoPeople { try restorePeopleMergeRow(row, table: "video_people") }
            try connection.execute("DELETE FROM person_tag_fields WHERE person_key = ?", [.text(survivor.key)])
            for row in snapshot.tagFields + snapshot.survivorTagFields {
                try restorePeopleMergeRow(row, table: "person_tag_fields")
            }

            // Remove voices that moved to the survivor, then put both sides back.
            for videoID in Set(snapshot.voiceProfiles.compactMap { $0["video_id"]?.intValue }) {
                try connection.execute("DELETE FROM voice_profiles WHERE person_key = ? AND video_id = ?",
                                       [.text(survivor.key), .integer(videoID)])
            }
            for row in snapshot.voiceProfiles + snapshot.survivorVoiceProfiles {
                try restorePeopleMergeRow(row, table: "voice_profiles")
            }

            for (sceneID, tag) in snapshot.sceneTags {
                try connection.execute("UPDATE OR IGNORE scene_tags SET tag = ? WHERE scene_id = ? AND tag = ?",
                                       [.text(tag), .integer(sceneID), .text(survivor.tag)])
                let changed = try connection.query("SELECT changes() AS count").first?["count"]?.intValue ?? 0
                if changed == 0 {
                    try connection.execute("INSERT OR IGNORE INTO scene_tags (scene_id, tag) VALUES (?, ?)",
                                           [.integer(sceneID), .text(tag)])
                }
            }
            // Restore full metadata and tags originally shared with the survivor too.
            for row in snapshot.sourceSceneTags + snapshot.survivorSceneTags {
                try restorePeopleMergeRow(row, table: "scene_tags")
            }
            for (id, key) in snapshot.speakerTurnIDs {
                try connection.execute("UPDATE speaker_turns SET person_key = ? WHERE id = ?", [.text(key), .integer(id)])
            }
            for (id, key) in snapshot.transcriptIDs {
                try connection.execute("UPDATE transcripts SET speaker_key = ? WHERE id = ?", [.text(key), .integer(id)])
            }
            for (id, personID) in snapshot.markerIDs {
                try connection.execute("UPDATE person_markers SET person_id = ? WHERE id = ?", [.integer(personID), .integer(id)])
            }
        }
    }

    /// Only called with table names above and columns captured by SELECT *.
    private func restorePeopleMergeRow(_ row: SQLRow, table: String, replacing: Bool = true) throws {
        let columns = row.keys.sorted()
        let names = columns.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ", ")
        let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
        let insert = replacing ? "INSERT OR REPLACE" : "INSERT"
        try connection.execute("\(insert) INTO \(table) (\(names)) VALUES (\(placeholders))",
                               columns.map { row[$0] ?? .null })
    }

    /// Create a person by hand (split target). Returns the new record.
    func createPerson(name: String) throws -> PersonRecord {
        var key = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character != "-" || result.last != "-" { result.append(character) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if key.isEmpty { key = "person" }
        // Uniquify against existing keys.
        let existing = Set(try fetchPeople().map(\.key))
        var candidate = key
        var counter = 2
        while existing.contains(candidate) {
            candidate = "\(key)-\(counter)"
            counter += 1
        }
        try connection.execute("INSERT INTO people (key, name) VALUES (?, ?)",
                               [.text(candidate), .text(name)])
        let id = connection.lastInsertRowID
        return PersonRecord(id: id, key: candidate, name: name, descriptor: "")
    }

    /// Split support: move one scene's person tag from `from` to `to`
    /// (nil `to` = the scene simply loses the person).
    func reassignScenePerson(sceneID: Int64, from: PersonRecord, to: PersonRecord?) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM scene_tags WHERE scene_id = ? AND tag = ?",
                                   [.integer(sceneID), .text(from.tag)])
            if let to {
                try connection.execute("INSERT OR IGNORE INTO scene_tags (scene_id, tag) VALUES (?, ?)",
                                       [.integer(sceneID), .text(to.tag)])
            }
        }
    }

    /// Everything that ties `from` to this video now ties `to` instead
    /// (nil = nobody). Other videos and person-owned fields are untouched.
    func reassignPerson(videoID: Int64, from: PersonRecord, to: PersonRecord?) throws {
        guard from.id != to?.id else { return }
        try connection.transaction {
            if let to {
                try connection.execute("""
                    UPDATE OR IGNORE scene_tags SET tag = ? WHERE tag = ?
                        AND scene_id IN (SELECT id FROM scenes WHERE video_id = ?)
                    """, [.text(to.tag), .text(from.tag), .integer(videoID)])
            }
            try connection.execute("""
                DELETE FROM scene_tags WHERE tag = ?
                    AND scene_id IN (SELECT id FROM scenes WHERE video_id = ?)
                """, [.text(from.tag), .integer(videoID)])
            try connection.execute("UPDATE speaker_turns SET person_key = ? WHERE video_id = ? AND person_key = ?",
                                   [to.map { .text($0.key) } ?? .null, .integer(videoID), .text(from.key)])
            try connection.execute("UPDATE transcripts SET speaker_key = ? WHERE video_id = ? AND speaker_key = ?",
                                   [to.map { .text($0.key) } ?? .null, .integer(videoID), .text(from.key)])

            for row in try connection.query("SELECT id, speaker_keys_json FROM topic_ranges WHERE video_id = ?",
                                            [.integer(videoID)]) {
                let keys = try JSONDecoder().decode([String].self,
                    from: Data((row["speaker_keys_json"]?.stringValue ?? "[]").utf8))
                guard keys.contains(from.key) else { continue }
                var replaced: [String] = []
                for key in keys {
                    if let key = key == from.key ? to?.key : key, !replaced.contains(key) {
                        replaced.append(key)
                    }
                }
                let json = String(decoding: try JSONEncoder().encode(replaced), as: UTF8.self)
                try connection.execute("UPDATE topic_ranges SET speaker_keys_json = ? WHERE id = ?",
                                       [.text(json), row["id"] ?? .null])
            }

            // Keep the target's own voice if both people had one in this video.
            if let to {
                try connection.execute("""
                    UPDATE OR IGNORE voice_profiles SET person_key = ? WHERE person_key = ? AND video_id = ?
                    """, [.text(to.key), .text(from.key), .integer(videoID)])
            }
            try connection.execute("DELETE FROM voice_profiles WHERE person_key = ? AND video_id = ?",
                                   [.text(from.key), .integer(videoID)])
            try connection.execute("UPDATE person_markers SET person_id = ? WHERE video_id = ? AND person_id = ?",
                                   [to.map { .integer($0.id) } ?? .null, .integer(videoID), .integer(from.id)])

            if let to {
                try mergePeopleRoster(videoID: videoID, from: from, to: to)
            } else {
                try connection.execute("DELETE FROM video_people WHERE video_id = ? AND person_id = ?",
                                       [.integer(videoID), .integer(from.id)])
            }
            // Keep even an orphaned people record; person_tag_fields belong to it.
        }
    }

    /// Shared by a whole-person merge and a single-video correction.
    private func mergePeopleRoster(videoID: Int64, from: PersonRecord, to: PersonRecord) throws {
        let source = try connection.query("SELECT ranges_json FROM video_people WHERE video_id = ? AND person_id = ?",
                                          [.integer(videoID), .integer(from.id)]).first
        let target = try connection.query("SELECT ranges_json FROM video_people WHERE video_id = ? AND person_id = ?",
                                          [.integer(videoID), .integer(to.id)]).first
        if let source, let target {
            // Union overlapping/touching intervals, retaining the target's portrait.
            let ranges = try [source, target].flatMap { row in
                try JSONDecoder().decode([ScriptTimeRange].self,
                    from: Data((row["ranges_json"]?.stringValue ?? "[]").utf8))
            }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            var merged: [ScriptTimeRange] = []
            for range in ranges {
                if let last = merged.last, range.start <= last.end {
                    merged[merged.count - 1].end = max(last.end, range.end)
                } else {
                    merged.append(range)
                }
            }
            let json = String(decoding: try JSONEncoder().encode(merged), as: UTF8.self)
            try connection.execute("UPDATE video_people SET ranges_json = ? WHERE video_id = ? AND person_id = ?",
                                   [.text(json), .integer(videoID), .integer(to.id)])
        } else if source != nil {
            try connection.execute("UPDATE video_people SET person_id = ? WHERE video_id = ? AND person_id = ?",
                                   [.integer(to.id), .integer(videoID), .integer(from.id)])
        }
        try connection.execute("DELETE FROM video_people WHERE video_id = ? AND person_id = ?",
                               [.integer(videoID), .integer(from.id)])
    }

    /// Counts every analysis/transcription set, including older runs.
    func personReferenceCounts(videoID: Int64, person: PersonRecord) throws -> (scenes: Int, turns: Int) {
        let scenes = try connection.query("""
            SELECT COUNT(*) AS count FROM scene_tags st JOIN scenes s ON s.id = st.scene_id
            WHERE s.video_id = ? AND st.tag = ?
            """, [.integer(videoID), .text(person.tag)]).first?["count"]?.intValue ?? 0
        let turns = try connection.query("""
            SELECT COUNT(*) AS count FROM speaker_turns WHERE video_id = ? AND person_key = ?
            """, [.integer(videoID), .text(person.key)]).first?["count"]?.intValue ?? 0
        return (Int(scenes), Int(turns))
    }

    func analyzedTags(videoID: Int64) throws -> Set<String> {
        let rows = try connection.query("SELECT tag FROM analyzed_tags WHERE video_id = ?", [.integer(videoID)])
        return Set(rows.compactMap { $0["tag"]?.stringValue })
    }

    func moments(videoID: Int64) throws -> [MomentRecord] {
        try connection.query("SELECT * FROM moments WHERE video_id = ? ORDER BY at_time", [.integer(videoID)]).map {
            MomentRecord(id: $0["id"]?.intValue ?? 0,
                         videoID: $0["video_id"]?.intValue ?? 0,
                         atTime: $0["at_time"]?.doubleValue ?? 0,
                         note: $0["note"]?.stringValue ?? "",
                         dialog: $0["dialog"]?.stringValue)
        }
    }
}
