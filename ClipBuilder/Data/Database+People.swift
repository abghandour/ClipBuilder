import Foundation

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
        try connection.transaction {
            try connection.execute("""
                INSERT OR IGNORE INTO person_tag_fields (person_key, field, value, provenance)
                SELECT ?, field, value, provenance FROM person_tag_fields WHERE person_key = ?
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
            try connection.execute("DELETE FROM people WHERE id = ?", [.integer(source.id)])
        }
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
