import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppStore {
    // MARK: - People

    /// One background batch; values remain proposals until the job's review is applied.
    func researchPeople(_ targets: [PersonRecord], fields: [String]? = nil, reason: String) {
        guard database != nil else { return }
        var seen = personResearchInFlight
        let targets = targets.filter {
            !$0.isUnnamed && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seen.insert($0.id).inserted
        }
        let requestedFields = (fields ?? TagTextWriter.profileFields).map(TagTextWriter.fieldKey)
        guard !targets.isEmpty, !requestedFields.isEmpty else { return }
        let requests = targets.map { person in
            var ids = personResearchVideoIDs[person.id] ?? []
            ids.formUnion(scenes.filter { $0.tags.contains(person.tag) }.map(\.videoID))
            let context = [person.descriptor] + videos.filter { ids.contains($0.id) }.map { video in
                let fight = fightResearch[video.id]
                return ([video.filename, fight?.fightLabel, fight?.event, fight?.fightDate]
                    .compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " · ")
            }
            return PersonResearchRequest(person: person, fields: requestedFields, context: context.joined(separator: "\n"))
        }
        let ids = Set(targets.map(\.id)), generation = profileGeneration
        personResearchInFlight.formUnion(ids)
        let ai = ai, runner = personResearchRunner
        jobs.start(.personResearch, title: "Person Research — \(targets.count) people",
                   project: activeProject, profileGeneration: generation,
                   cleanup: { [weak self] in
                       guard let self, self.profileGeneration == generation else { return }
                       self.personResearchInFlight.subtract(ids)
                   }) { log in
            log("Person research: \(reason)")
            let outcomes = try await PersonResearchService().runBatch(requests, ai: ai, runner: runner, log: log)
            guard outcomes.contains(where: { !$0.proposals.isEmpty || $0.category != nil }) else {
                throw AppJobEmptyResult(message: "No supported profile values were found. See the job log for details.")
            }
            return .personResearch(outcomes: outcomes)
        }
    }

    /// Called with the pre-pass registry so newly guessed identities are never researched.
    func refreshPersonRecords(roster: [VideoPersonRecord], existingPeople: [PersonRecord], now: Date = Date()) async {
        guard let database else { return }
        let generation = profileGeneration
        for row in roster { personResearchVideoIDs[row.personID, default: []].insert(row.videoID) }
        let rosterIDs = Set(roster.map(\.personID))
        let fighters = existingPeople.filter { rosterIDs.contains($0.id) && $0.category == .fighter && !$0.isUnnamed }
        guard !fighters.isEmpty else { return }
        do {
            let fields = try await database.personTagFieldsByPerson()
            guard generation == profileGeneration, self.database === database else { return }
            let stale = fighters.filter {
                PersonResearch.needsRecordRefresh(fields: fields[$0.key] ?? [], person: $0, now: now)
            }
            researchPeople(stale, fields: ["MMA record"], reason: "record refresh")
        } catch {
            guard generation == profileGeneration else { return }
            appendLog(\.analysisLog, ["Could not check person records: \(error.localizedDescription)"])
        }
    }

    func applyPersonResearch(_ outcomes: [PersonResearchOutcome], proposalIDs: Set<String>,
                             categoryKeys: Set<String>, generation: Int) async throws {
        guard generation == profileGeneration, let database else { throw CancellationError() }
        try await database.applyPersonResearch(outcomes, proposalIDs: proposalIDs, categoryKeys: categoryKeys)
        guard generation == profileGeneration, self.database === database else { throw CancellationError() }
        let updated = try await database.fetchPeople()
        guard generation == profileGeneration, self.database === database else { throw CancellationError() }
        people = updated
        personTagFieldsVersion &+= 1
        await refreshAllNow()
    }

    func renamePerson(_ person: PersonRecord, to name: String) {
        guard let database else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = profileGeneration
        Task {
            do {
                try await database.renamePerson(id: person.id, name: trimmed)
                let updated = try await database.fetchPeople()
                guard generation == profileGeneration, self.database === database else { return }
                people = updated
                if person.isUnnamed, !trimmed.isEmpty, let named = updated.first(where: { $0.id == person.id }) {
                    researchPeople([named], reason: "named")
                }
            } catch {
                guard generation == profileGeneration else { return }
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
        guard source.id != target.id else { return }
        mergePeople([source], into: target)
    }

    /// The entire selection and optional rename share one undo snapshot.
    func mergePeople(_ selected: [PersonRecord], into survivor: PersonRecord,
                     renamingTo name: String? = nil) {
        guard let database else { return }
        var seen: Set<Int64> = [survivor.id]
        let sources = selected.filter { seen.insert($0.id).inserted }
        guard !sources.isEmpty else { return }
        let generation = profileGeneration
        Task {
            do {
                let snapshot = try await database.mergePeople(sources: sources, into: survivor, renamingTo: name)
                guard generation == profileGeneration, self.database === database else { return }
                previousPeopleMerge = snapshot
                refreshPeopleMergeReferences(snapshot)
                await refreshAllNow()
            } catch {
                guard generation == profileGeneration, self.database === database else { return }
                presentError("Could not merge the people", error)
            }
        }
    }

    func undoPeopleMerge() async -> Bool {
        guard let database, let snapshot = previousPeopleMerge else { return false }
        let generation = profileGeneration
        do {
            try await database.restorePeopleMerge(snapshot)
            guard generation == profileGeneration, self.database === database else { return false }
            previousPeopleMerge = nil
            refreshPeopleMergeReferences(snapshot)
            await refreshAllNow()
            guard generation == profileGeneration, self.database === database else { return false }
            appendLog(\.analysisLog, ["Undid the merge into \(snapshot.survivor.displayName): \(snapshot.sources.count) people restored"])
            return true
        } catch {
            guard generation == profileGeneration, self.database === database else { return false }
            presentError("Could not undo the people merge", error)
            return false
        }
    }

    private func refreshPeopleMergeReferences(_ snapshot: PeopleMergeSnapshot) {
        // Speaker/transcript caches can contain identities even without roster rows.
        for video in videos { invalidatePersonReferences(videoID: video.id) }
        personTagFieldsVersion &+= 1
        personPortraitVersions[snapshot.survivor.id, default: 0] &+= 1
        for row in snapshot.sources {
            if let id = row["id"]?.intValue { personPortraitVersions[id, default: 0] &+= 1 }
        }
    }

    /// Apply the end-of-analysis people review in one pass: names land first,
    /// then duplicates fold into their targets. Merge targets are resolved
    /// transitively (A→B while B→C sends A's scenes to C), so chained
    /// assignments in one review can't point at a person that just vanished.
    func applyPeopleReview(names: [String: String], merges: [String: Int64]) {
        guard let database else { return }
        let generation = profileGeneration
        Task {
            do {
                var current = try await database.fetchPeople()
                var confirmedIDs: Set<Int64> = []
                for (key, name) in names {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard merges[key] == nil, !trimmed.isEmpty,
                          let record = current.first(where: { $0.key == key }) else { continue }
                    try await database.renamePerson(id: record.id, name: trimmed)
                    confirmedIDs.insert(record.id)
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
                let survivors = try await database.fetchPeople()
                guard generation == profileGeneration, self.database === database else { return }
                people = survivors
                await refreshAllNow()
                guard generation == profileGeneration, self.database === database else { return }
                researchPeople(survivors.filter { confirmedIDs.contains($0.id) }, reason: "new people")
            } catch {
                guard generation == profileGeneration else { return }
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

    /// Correct a mistaken identity everywhere within one source video.
    func reassignPerson(in video: VideoRecord, from person: PersonRecord,
                        to target: PersonRecord?, newPersonName: String? = nil) {
        guard let database else { return }
        let generation = profileGeneration
        let profileName = activeProfile.profileName
        Task {
            do {
                var destination = target
                if let newPersonName {
                    let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    destination = try await database.createPerson(name: name)
                }
                guard destination?.id != person.id else { return }
                let counts = try await database.personReferenceCounts(videoID: video.id, person: person)
                try await database.reassignPerson(videoID: video.id, from: person, to: destination)
                LearnedCache.invalidate(profile: profileName)
                guard generation == profileGeneration else { return }
                invalidatePersonReferences(videoID: video.id)
                appendLog(\.analysisLog, ["Moved \(person.displayName) to \(destination?.displayName ?? "Nobody") in \(video.filename): \(counts.scenes) scenes, \(counts.turns) speaker turns"])
                await refreshAllNow()
                guard generation == profileGeneration else { return }
                // Avatar fallback reads scene tags from the store. Reload after
                // the snapshot so it cannot crop a scene under the old identity.
                for id in [person.id] + (destination.map { [$0.id] } ?? []) {
                    personPortraitVersions[id, default: 0] &+= 1
                }
            } catch {
                guard generation == profileGeneration else { return }
                presentError("Could not reassign the person in this video", error)
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
        if !video.isPresent {
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
