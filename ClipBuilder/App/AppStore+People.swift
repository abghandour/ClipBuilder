import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppStore {
    // MARK: - People

    func renamePerson(_ person: PersonRecord, to name: String) {
        guard let database else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await database.renamePerson(id: person.id, name: trimmed)
                people = try await database.fetchPeople()
            } catch {
                presentError("Could not rename the person", error)
            }
        }
    }

    func deletePerson(_ person: PersonRecord) {
        guard let database else { return }
        Task {
            do {
                try await database.deletePerson(person)
                await refreshAllNow()
            } catch {
                presentError("Could not delete the person", error)
            }
        }
    }

    func mergePeople(source: PersonRecord, into target: PersonRecord) {
        guard let database, source.id != target.id else { return }
        Task {
            do {
                try await database.mergePeople(source: source, into: target)
                await refreshAllNow()
            } catch {
                presentError("Could not merge the people", error)
            }
        }
    }

    /// Merge several people into one: every other selected person's scenes
    /// are retagged onto the survivor. The survivor keeps its name unless
    /// the merge sheet supplied an edited one.
    func mergePeople(_ selected: [PersonRecord], into survivor: PersonRecord,
                     renamingTo name: String? = nil) {
        guard let database else { return }
        Task {
            do {
                for person in selected where person.id != survivor.id {
                    try await database.mergePeople(source: person, into: survivor)
                }
                if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !trimmed.isEmpty, trimmed != survivor.name {
                    try await database.renamePerson(id: survivor.id, name: trimmed)
                }
                await refreshAllNow()
            } catch {
                presentError("Could not merge the people", error)
            }
        }
    }

    /// Apply the end-of-analysis people review in one pass: names land first,
    /// then duplicates fold into their targets. Merge targets are resolved
    /// transitively (A→B while B→C sends A's scenes to C), so chained
    /// assignments in one review can't point at a person that just vanished.
    func applyPeopleReview(names: [String: String], merges: [String: Int64]) {
        guard let database else { return }
        Task {
            do {
                var current = try await database.fetchPeople()
                for (key, name) in names {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard merges[key] == nil, !trimmed.isEmpty,
                          let record = current.first(where: { $0.key == key }) else { continue }
                    try await database.renamePerson(id: record.id, name: trimmed)
                }
                current = try await database.fetchPeople()
                let mergesByID: [Int64: Int64] = Dictionary(uniqueKeysWithValues:
                    merges.compactMap { key, targetID in
                        current.first { $0.key == key }.map { ($0.id, targetID) }
                    })
                func resolve(_ id: Int64) -> Int64 {
                    var seen: Set<Int64> = []
                    var id = id
                    while let next = mergesByID[id], seen.insert(id).inserted { id = next }
                    return id
                }
                for (sourceID, targetID) in mergesByID {
                    let resolved = resolve(targetID)
                    // A resolved target that is itself still a merge source
                    // means a cycle (A→B, B→A) — skip rather than merge into
                    // a person about to disappear.
                    guard mergesByID[resolved] == nil,
                          let source = current.first(where: { $0.id == sourceID }),
                          let target = current.first(where: { $0.id == resolved }),
                          source.id != target.id else { continue }
                    try await database.mergePeople(source: source, into: target)
                }
                await refreshAllNow()
            } catch {
                presentError("Could not apply the people review", error)
            }
        }
    }

    /// Split support: move one scene from a person to another (or a brand-new
    /// person named `newPersonName`, or nobody when both are nil).
    func reassignScene(_ scene: SceneRecord, from person: PersonRecord,
                       to target: PersonRecord?, newPersonName: String? = nil) {
        guard let database else { return }
        Task {
            do {
                var destination = target
                if destination == nil, let newPersonName {
                    destination = try await database.createPerson(name: newPersonName)
                }
                try await database.reassignScenePerson(sceneID: scene.id, from: person,
                                                       to: destination)
                await refreshAllNow()
            } catch {
                presentError("Could not reassign the scene", error)
            }
        }
    }

    // MARK: - Video notes

    func videoNotes(for videoID: Int64) async -> [VideoNote] {
        guard let database else { return [] }
        return (try? await database.videoNotes(videoID: videoID)) ?? []
    }

    /// Add a timestamped note; returns the video's refreshed note list.
    /// `provenance` marks AI-written notes (saved soundbites).
    func addVideoNote(videoID: Int64, at atTime: Double, text: String,
                      provenance: AIProvenance? = nil) async -> [VideoNote] {
        guard let database else { return [] }
        do {
            try await database.addVideoNote(videoID: videoID, at: atTime, note: text,
                                            provenance: provenance)
        } catch {
            presentError("Could not save the note", error)
        }
        return (try? await database.videoNotes(videoID: videoID)) ?? []
    }

    func deleteVideoNote(_ note: VideoNote) async -> [VideoNote] {
        guard let database else { return [] }
        do {
            try await database.deleteVideoNote(id: note.id)
        } catch {
            presentError("Could not delete the note", error)
        }
        return (try? await database.videoNotes(videoID: note.videoID)) ?? []
    }

    // MARK: - Person markers

    func personMarkers(for videoID: Int64) async -> [PersonMarker] {
        guard let database else { return [] }
        return (try? await database.personMarkers(videoID: videoID)) ?? []
    }

    /// Draw a new identity box; returns the video's refreshed marker list.
    func addPersonMarker(videoID: Int64, at atTime: Double,
                         x: Double, y: Double, width: Double, height: Double) async -> [PersonMarker] {
        guard let database else { return [] }
        do {
            try await database.addPersonMarker(videoID: videoID, at: atTime,
                                               x: x, y: y, width: width, height: height)
        } catch {
            presentError("Could not save the person marker", error)
        }
        return (try? await database.personMarkers(videoID: videoID)) ?? []
    }

    func updatePersonMarker(_ marker: PersonMarker) async -> [PersonMarker] {
        guard let database else { return [] }
        do {
            try await database.updatePersonMarker(marker)
        } catch {
            presentError("Could not update the person marker", error)
        }
        return (try? await database.personMarkers(videoID: marker.videoID)) ?? []
    }

    func deletePersonMarker(_ marker: PersonMarker) async -> [PersonMarker] {
        guard let database else { return [] }
        do {
            try await database.deletePersonMarker(id: marker.id)
        } catch {
            presentError("Could not delete the person marker", error)
        }
        return (try? await database.personMarkers(videoID: marker.videoID)) ?? []
    }

    /// The people pass's portrait of a person as a marker-shaped box plus
    /// its video URL, for face avatars.
    func personRosterPortrait(for personID: Int64) async -> (url: URL, marker: PersonMarker)? {
        guard let database, let portrait = try? await database.rosterPortrait(personID: personID),
              !portrait.videoPath.isEmpty else { return nil }
        let marker = PersonMarker(id: 0, videoID: 0, atTime: portrait.time,
                                  x: portrait.box.x, y: portrait.box.y,
                                  width: portrait.box.w, height: portrait.box.h)
        return (URL(fileURLWithPath: portrait.videoPath), marker)
    }

    /// The person's first marker plus its video URL, for face avatars.
    func personMarkerReference(for personID: Int64) async -> (url: URL, marker: PersonMarker)? {
        guard let database else { return nil }
        guard let reference = try? await database.markerReference(personID: personID),
              !reference.videoPath.isEmpty else { return nil }
        return (URL(fileURLWithPath: reference.videoPath), reference.marker)
    }

    /// Hide/unhide a person on the People screen. Hidden people keep their
    /// identity — detection still reuses their key and their scene tags stay
    /// — they just move to the Hidden bucket at the bottom of the list.
    func setPersonHidden(_ person: PersonRecord, hidden: Bool) {
        guard let database else { return }
        Task {
            do {
                try await database.setPersonHidden(id: person.id, hidden: hidden)
                people = try await database.fetchPeople()
            } catch {
                presentError("Could not update the person", error)
            }
        }
    }

    /// File a person under a role on the People screen, or clear it.
    func setPersonCategory(_ person: PersonRecord, category: PersonCategory?) {
        guard let database else { return }
        Task {
            do {
                try await database.setPersonCategory(id: person.id, category: category)
                people = try await database.fetchPeople()
            } catch {
                presentError("Could not update the person", error)
            }
        }
    }

    /// File several people at once — the People Roles review's Apply.
    func setPersonCategories(_ assignments: [(id: Int64, category: PersonCategory?)]) async throws {
        guard let database else { return }
        try await database.setPersonCategories(assignments)
        people = try await database.fetchPeople()
    }

    /// People with no role yet whom the wizard can reason about — hidden
    /// people are skipped, they were tucked away on purpose.
    var uncategorizedPeople: [PersonRecord] {
        people.filter { $0.category == nil && !$0.hidden }
    }

    /// People Roles wizard: gather what the footage says about each
    /// uncategorized person and ask the model for a role per person. The
    /// answer is a proposal list for the review sheet; nothing is written.
    func inferPersonRoles(people targets: [PersonRecord], provider: String?, model: String?,
                          log: @escaping @Sendable (String) -> Void) async throws
        -> AIOutcome<[PersonRoleInference.Proposal]> {
        guard let database else { throw AIError.notConfigured("No profile is open.") }
        guard !targets.isEmpty else { throw AppJobEmptyResult(message: "Everyone already has a category.") }
        let scenes = scenes, videos = videos, domain = activeProfile.effectiveDomain
        let videosByID = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })

        log("Reading scenes and transcripts for \(targets.count) people…")
        var dossiers: [PersonRoleInference.Dossier] = []
        var transcriptCache: [Int64: (rows: [TranscriptRow], turns: [SpeakerTurn])] = [:]
        for (index, person) in targets.enumerated() {
            try Task.checkCancellation()
            let theirScenes = scenes.filter { !$0.ignored && $0.tags.contains(person.tag) }
            var videoIDs = Set(theirScenes.map(\.videoID))
            videoIDs.formUnion(try await database.fetchVideoIDs(personID: person.id))
            let videoLines = videoIDs.compactMap { videosByID[$0] }
                .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
                .map { "\($0.filename) (\($0.type?.label ?? "untyped"))" }
            let sceneLines = theirScenes.prefix(PersonRoleInference.maxScenesPerPerson).map { scene in
                let tags = scene.tags.filter { !$0.hasPrefix("person:") && !$0.hasPrefix("vip:") }
                let narrative = scene.narrative?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return "\(scene.videoFilename): [\(tags.joined(separator: ", "))]"
                    + (narrative.isEmpty ? "" : " \(narrative.prefix(PersonRoleInference.maxQuoteLength))")
            }
            var quotes: [String] = []
            for videoID in videoIDs.sorted() where quotes.count < PersonRoleInference.maxQuotesPerPerson {
                if transcriptCache[videoID] == nil {
                    transcriptCache[videoID] = (try await database.fetchTranscripts(videoID: videoID),
                                                try await database.fetchSpeakerTurns(videoID: videoID))
                }
                let cached = transcriptCache[videoID]!
                quotes += PersonRoleInference.quotes(for: person.key, transcripts: cached.rows, turns: cached.turns)
            }
            dossiers.append(.init(personID: person.id, name: person.displayName, descriptor: person.descriptor,
                                  videos: videoLines, scenes: Array(sceneLines),
                                  quotes: Array(quotes.prefix(PersonRoleInference.maxQuotesPerPerson))))
            log("PROGRESS:\(Double(index + 1) / Double(targets.count) * 0.4)")
        }

        log("Asking the model for a role per person…")
        let response = try await ai.call(prompt: PersonRoleInference.prompt(dossiers: dossiers, domain: domain),
                                         task: .roles, model: model, provider: provider, timeout: 240, log: log)
        let proposals = PersonRoleInference.parse(response.text, personIDs: targets.map(\.id))
        guard !proposals.isEmpty else {
            throw AIError.unusableResponse("No roles could be read from the model's reply.")
        }
        log("Proposed roles for \(proposals.count) of \(targets.count) people.")
        return AIOutcome(value: proposals, provenance: response.provenance)
    }

    /// Hand-pick a person's avatar frame — or reset to automatic with nils.
    /// The picked frame + face box render everywhere the avatar shows.
    func setPersonAvatar(_ person: PersonRecord, videoID: Int64?, time: Double?,
                         box: VideoPersonRecord.PortraitBox?) {
        guard let database else { return }
        let boxJSON = box.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        Task {
            do {
                try await database.setPersonAvatar(id: person.id, videoID: videoID,
                                                   time: time, boxJSON: boxJSON)
                people = try await database.fetchPeople()
            } catch {
                presentError("Could not save the avatar", error)
            }
        }
    }

    /// "New Person…" from a marker's dropdown — creates the registry entry
    /// and refreshes the people list. Returns the new record.
    func createPerson(named name: String) async -> PersonRecord? {
        guard let database else { return nil }
        do {
            let person = try await database.createPerson(name: name)
            people = try await database.fetchPeople()
            return person
        } catch {
            presentError("Could not create the person", error)
            return nil
        }
    }

    /// Rename a source video: move the file in the Input folder and update
    /// its row (scenes join the videos table, so they follow). Content
    /// hashing means the folder watcher won't re-register it as new.
    /// `provenance` is the model that proposed the name (the File Name
    /// Wizard, the pipeline's rename step); nil for a hand rename.
    func renameVideo(_ video: VideoRecord, to rawName: String, provenance: AIProvenance? = nil) {
        guard let database else { return }
        if video.driveFileID != nil, !FileManager.default.fileExists(atPath: video.path) {
            let generation = profileGeneration
            let profile = activeProfile.profileName
            Task {
                do {
                    _ = try await googleDrive.fetch(video.driveMedia, profile: profile)
                    guard generation == profileGeneration else { return }
                    renameVideo(video, to: rawName, provenance: provenance)
                } catch { presentError("Could not fetch the video to rename", error) }
            }
            return
        }
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty, name != video.filename else { return }
        let ext = video.url.pathExtension
        if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() {
            name += ".\(ext)"
        }
        let destination = video.url.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            presentError("A file named \(name) already exists in the Input folder.")
            return
        }
        do {
            try FileManager.default.moveItem(at: video.url, to: destination)
        } catch {
            presentError("Could not rename the video", error)
            return
        }
        Task {
            do {
                try await database.renameVideo(id: video.id, filename: name, path: destination.path,
                                               provenance: provenance)
                await renameAnalysisBatches(for: video, newFilename: name)
                await refreshAllNow()
            } catch {
                presentError("Could not save the new name", error)
            }
        }
    }

    /// Batch labels carry the filename — after a video rename, rebuild every
    /// label still derived from the old name into the current format:
    /// "<name without extension> MM/dd/yy" (+ " v<n>" from the second batch
    /// of the video on), keeping a trailing "(start–end)" trim-window
    /// suffix. Labels the user hand-renamed (no trace of the old filename)
    /// are left alone.
    private func renameAnalysisBatches(for video: VideoRecord, newFilename: String) async {
        guard let database else { return }
        let oldBase = (video.filename as NSString).deletingPathExtension
        let newBase = (newFilename as NSString).deletingPathExtension
        let runs = ((try? await database.fetchAnalysisRuns()) ?? [])
            .filter { $0.videoID == video.id }
            .sorted { $0.id < $1.id }
        // Auto-derived labels: the legacy "… — as of <date>" stamp or the
        // current "… MM/dd/yy [vN] [(trim)]" one. Catches labels still
        // carrying a name from before an earlier rename, too.
        func isDerived(_ label: String) -> Bool {
            label.contains(video.filename) || label.contains(oldBase)
                || label.contains(" — as of ")
                || label.range(of: #"\d{2}/\d{2}/\d{2}( v\d+)?( \([0-9:.]+–[0-9:.]+\))?$"#,
                               options: .regularExpression) != nil
        }
        for (index, run) in runs.enumerated() where isDerived(run.name) {
            var label = "\(newBase) \(Self.shortDate(run.createdAt))"
            if index >= 1 { label += " v\(index + 1)" }
            if let window = run.name.range(of: #" \([0-9:.]+–[0-9:.]+\)$"#,
                                           options: .regularExpression) {
                label += String(run.name[window])
            }
            try? await database.renameAnalysisRun(id: run.id, name: label)
        }
    }

    /// SQLite "YYYY-MM-DD hh:mm:ss" (UTC) → local "MM/dd/yy"; today if
    /// unparseable. The full timestamp must convert to local time BEFORE
    /// dropping the time, else late-evening batches land on the wrong day.
    private static func shortDate(_ sqliteDate: String?) -> String {
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.dateFormat = "MM/dd/yy"
        guard let sqliteDate else { return output.string(from: .now) }
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.timeZone = TimeZone(identifier: "UTC")
        input.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = input.date(from: sqliteDate) {
            return output.string(from: date)
        }
        // Date-only fallback: keep it in UTC on both ends so the calendar
        // day survives.
        input.dateFormat = "yyyy-MM-dd"
        if let date = input.date(from: String(sqliteDate.prefix(10))) {
            output.timeZone = TimeZone(identifier: "UTC")
            return output.string(from: date)
        }
        return output.string(from: .now)
    }
}
