import Foundation

/// Express Transcript mode: picks are stored per video and project as the user adds them;
/// moving to Settings turns them into selections in list order.
extension AppStore {
    /// Load the transcript, speaker labels and the video's saved picks.
    func loadMiniTranscript(flow: MiniWizardFlow) {
        guard let video = flow.video, let database, let projectID = activeProjectID, !isWizardRunning else { return }
        let generation = profileGeneration
        guard video.isPresent else { presentError(VideoRecord.notPresentReason); return }
        var options = WizardOptions()
        options.projectID = projectID
        options.sourceVideoPaths = [video.path ?? ""]
        options.sourcesRestricted = true
        options.formatPreset = flow.isPodcastOrInterview ? "podcast" : "custom"
        options.useBRoll = flow.isPodcastOrInterview && MiniWizardSettings.remembered(profile: activeProfile).includesBRoll
        options.manualBRoll = true
        options.critiqueLoop = false
        options.workflow = .automatic
        selectMiniFootage(flow: flow)
        guard miniRuns[.transcript] == nil, !isLoadingMiniFootage else { return }
        let loadID = beginMiniFootageLoad(stage: "Loading transcript")
        miniFootageTask = Task {
            defer { finishMiniFootageLoad(loadID) }
            do {
                _ = try? await transcriptPickSaveTask?.value
                try Task.checkCancellation()
                let (setKey, rows, picks) = try await database.expressTranscript(projectID: projectID, videoID: video.id)
                guard generation == profileGeneration, activeProjectID == projectID else { return }
                let speakers = await speakerTurns(videoID: video.id)
                try Task.checkCancellation()
                guard generation == profileGeneration, activeProjectID == projectID else { return }
                let people = people
                let transcript = await Task.detached(priority: .userInitiated) {
                    let namedTurns = TranscriptSpeakers.named(speakers.turns, roster: speakers.roster)
                    let labels = rows.reduce(into: [Int64: String]()) { labels, row in
                        labels[row.id] = TranscriptSpeakers.label(for: row, turns: namedTurns,
                                                                 roster: speakers.roster, people: people)
                    }
                    return MiniWizardTranscript(rows: rows, labels: labels, picks: picks,
                        speakerSpans: TranscriptSpeakers.spans(turns: namedTurns, roster: speakers.roster),
                        setKey: setKey)
                }.value
                try Task.checkCancellation()
                guard miniFootageLoadID == loadID, generation == profileGeneration else { return }
                let batch = MiniWizardMemory.batchID(profileName: activeProfile.profileName,
                    projectID: projectID, videoID: video.id, kind: .transcript)
                let saved = try await database.miniSavedCandidates(projectID: projectID, miniBatch: batch)
                guard !Task.isCancelled, generation == profileGeneration, activeProjectID == projectID else { return }
                guard !Task.isCancelled, miniFootageLoadID == loadID else { return }
                miniRuns[.transcript] = MiniWizardRun(projectID: projectID, video: video, footageKind: .transcript,
                    length: .automatic, batchID: batch, candidates: saved, options: options,
                    transcript: transcript)
                appendLog(\.wizardLog, ["Express: transcript ready, \(picks.count) saved picks."])
            } catch is CancellationError {
                if miniFootageLoadID == loadID, generation == profileGeneration { appendLog(\.wizardLog, ["Loading transcript stopped."]) }
            } catch {
                if !Task.isCancelled, miniFootageLoadID == loadID, generation == profileGeneration { presentError("Could not load the transcript", error) }
            }
        }
    }

    /// Express: use another transcript set of the source. Picks, Q&A
    /// sections and Highlights are those made on that set.
    func setMiniTranscriptSet(videoID: Int64, key: String) {
        Task { await changeMiniTranscriptSet(videoID: videoID, key: key) }
    }

    /// Returns once Express has been moved to the set; false when it could not.
    @discardableResult
    func changeMiniTranscriptSet(videoID: Int64, key: String) async -> Bool {
        guard let database, !isWizardRunning, !miniEditsBlocked else { return false }
        let generation = profileGeneration
        _ = try? await transcriptPickSaveTask?.value
        do {
            _ = try await database.switchTranscriptionSet(videoID: videoID, key: key)
            guard generation == profileGeneration else { return false }
            await transcriptSetChanged(videoID: videoID)
            return true
        } catch {
            presentError("Could not change the transcript", error)
            return false
        }
    }

    func renameTranscriptSet(videoID: Int64, key: String, name: String) async {
        guard let database else { return }
        do {
            try await database.setTranscriptionSetName(videoID: videoID, key: key, name: name)
            transcriptSetNamesVersion &+= 1
        } catch { presentError("Could not rename the transcript", error) }
    }

    /// The pin was changed in the database (the Express row, the Transcript
    /// sheet): refresh the library, which notices the move in
    /// `transcriptSetsMoved` and reloads Express.
    func transcriptSetChanged(videoID: Int64) async {
        invalidatePersonReferences(videoID: videoID)
        await refreshAllNow()
    }

    /// Called with every new set of transcript facts. Remembers, per
    /// profile, the set each video was last seen on, and when a video shows
    /// up on another one, the Highlights of the set it left go from every
    /// project's reel. Kept in defaults because facts cover only the open
    /// project: a set that changed while its project was closed is noticed
    /// when the project comes back. `previous` (the same library's facts
    /// before this refresh) stands in for videos not remembered yet.
    func noteTranscriptSets(previous: [Int64: TranscriptFact]) {
        let defaultsKey = "mini.activeSets.\(activeProfile.profileName)"
        var known = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        var changed = false
        for (videoID, fact) in transcriptFacts {
            let now = fact.transcriptionKey
            guard !now.isEmpty else { continue }
            let id = String(videoID)
            let old = known[id] ?? previous[videoID]?.transcriptionKey
            if let old, !old.isEmpty, old != now {
                MiniWizardMemory.stampLegacyHighlightBatches(profileName: activeProfile.profileName, videoID: videoID,
                                                             setKey: old)
                dropMiniReelHighlights(videoID: videoID)
            }
            if known[id] != now { known[id] = now; changed = true }
        }
        if changed { UserDefaults.standard.set(known, forKey: defaultsKey) }
    }

    /// Called when a library refresh brings new transcript facts for the
    /// same profile and project. A video whose active set differs from the
    /// one known before (a pin here or on a teammate's Mac, a new
    /// transcription, a deleted set) leaves what Express read from the old
    /// set behind: history, loaded sections, loads and opens in flight go,
    /// and the page reloads. Runs synchronously with the new facts in
    /// place, so nothing can restore the old set's Highlights in between.
    func transcriptSetsMoved(from previous: [Int64: TranscriptFact]) {
        // Facts list only videos with a transcript, so a video that gained
        // its first set or lost its last one is on one side only.
        for video in videos {
            let videoID = video.id
            let old = previous[videoID]?.transcriptionKey
            let now = transcriptFacts[videoID]?.transcriptionKey
            guard old != now else { continue }
            // Transcript picks and exchanges of the set that was left go
            // from the open reel, whichever tab is showing.
            refreshMiniReelSections(videoID: videoID)
            guard miniFootageVideoID == videoID || miniRuns.values.contains(where: { $0.video.id == videoID }) else { continue }
            forgetAllMiniUndo()
            cancelMiniFootageLoad()
            // A history entry being opened would land under the new set.
            highlightOpenToken += 1
            if miniRuns[.highlights]?.video.id == videoID { miniRuns[.highlights] = nil }
            transcriptEdited(videoID: videoID)
            appendLog(\.wizardLog, ["Express: the source's transcript changed; footage reloaded."])
        }
    }

    private func currentTranscriptRun() -> MiniWizardRun? {
        guard let run = miniRuns[.transcript], run.projectID == activeProjectID,
              run.transcript != nil, !isWizardRunning, !miniEditsBlocked else { return nil }
        return run
    }

    /// Serial writes keep positions and ranges in the order the user made them.
    private func enqueueTranscriptPickWrite(_ context: String, batchID: String,
                                            write: @escaping @Sendable (Database) async throws -> Void,
                                            then apply: @escaping @MainActor () -> Void = {}) {
        guard let database else { return }
        let previous = transcriptPickSaveTask
        let generation = profileGeneration
        transcriptPickSaveTask = Task {
            _ = try? await previous?.value
            do {
                try await write(database)
            } catch {
                if generation == profileGeneration { presentError(context, error) }
                throw error
            }
            guard generation == profileGeneration, miniRuns[.transcript]?.batchID == batchID else { return }
            apply()
        }
    }

    func addMiniTranscriptPick(range: ClosedRange<Double>) {
        guard let run = currentTranscriptRun() else { return }
        recordMiniUndo(.transcript)
        let videoID = run.video.id
        let projectID = run.projectID
        let batchID = run.batchID
        let shownSet = TranscriptPickSet.shown(run.transcript?.setKey)
        let previous = transcriptPickSaveTask
        let generation = profileGeneration
        guard let database else { return }
        transcriptPickSaveTask = Task {
            _ = try? await previous?.value
            let pick: TranscriptPick
            do {
                pick = try await database.addTranscriptPick(projectID: projectID, videoID: videoID,
                                                            start: range.lowerBound, end: range.upperBound, set: shownSet)
            } catch {
                if generation == profileGeneration { presentError("Could not add the pick", error) }
                throw error
            }
            guard generation == profileGeneration, miniRuns[.transcript]?.batchID == batchID else { return }
            miniRuns[.transcript]?.transcript?.picks.append(pick)
        }
    }

    /// Cut one pick in two at `time`: the pick keeps its first half and a
    /// new pick with the second half lands right after it in the list.
    func splitMiniTranscriptPick(_ id: Int64, at time: Double) {
        guard let run = currentTranscriptRun(), let picks = run.transcript?.picks,
              let index = picks.firstIndex(where: { $0.id == id }) else { return }
        let pick = picks[index]
        let minimum = TranscriptQATrim.minimumSpan
        guard time - pick.start >= minimum, pick.end - time >= minimum else { return }
        recordMiniUndo(.transcript)
        // The first half shows at once; both halves are written together.
        miniRuns[.transcript]?.transcript?.picks[index].end = time
        let videoID = run.video.id
        let projectID = run.projectID
        let batchID = run.batchID
        let end = pick.end
        let kept = pick.kept
        let order = picks.map(\.id)
        let previous = transcriptPickSaveTask
        let generation = profileGeneration
        guard let database else { return }
        transcriptPickSaveTask = Task {
            _ = try? await previous?.value
            let added: TranscriptPick
            do {
                added = try await database.splitTranscriptPick(projectID: projectID, videoID: videoID, id: id,
                    start: pick.start, at: time, end: end, kept: kept, order: order, index: index + 1,
                    set: .shown(run.transcript?.setKey))
            } catch {
                if generation == profileGeneration {
                    // Nothing was written: the pick on the page is whole again.
                    if miniRuns[.transcript]?.batchID == batchID,
                       let at = miniRuns[.transcript]?.transcript?.picks.firstIndex(where: { $0.id == id }) {
                        miniRuns[.transcript]?.transcript?.picks[at].end = end
                    }
                    presentError("Could not split the pick", error)
                }
                throw error
            }
            guard generation == profileGeneration, miniRuns[.transcript]?.batchID == batchID,
                  var current = miniRuns[.transcript]?.transcript?.picks else { return }
            let at = current.firstIndex(where: { $0.id == id }).map { $0 + 1 } ?? current.count
            current.insert(added, at: at)
            miniRuns[.transcript]?.transcript?.picks = current.enumerated().map { position, pick in
                var pick = pick
                pick.position = position
                return pick
            }
        }
    }

    func setMiniTranscriptPickRange(_ id: Int64, start: Double, end: Double) {
        guard let run = currentTranscriptRun(), end > start,
              let index = run.transcript?.picks.firstIndex(where: { $0.id == id }) else { return }
        recordMiniUndo(.transcript)
        miniRuns[.transcript]?.transcript?.picks[index].start = start
        miniRuns[.transcript]?.transcript?.picks[index].end = end
        let projectID = run.projectID
        enqueueTranscriptPickWrite("Could not save the pick", batchID: run.batchID) { database in
            try await database.setTranscriptPickRange(projectID: projectID, id: id, start: start, end: end)
        }
    }

    /// `ids` is the full list in its new order.
    func reorderMiniTranscriptPicks(_ ids: [Int64]) {
        guard let run = currentTranscriptRun(), let picks = run.transcript?.picks else { return }
        let byID = Dictionary(uniqueKeysWithValues: picks.map { ($0.id, $0) })
        let ordered = ids.compactMap { byID[$0] } + picks.filter { !ids.contains($0.id) }
        guard ordered.map(\.id) != picks.map(\.id) else { return }
        recordMiniUndo(.transcript)
        miniRuns[.transcript]?.transcript?.picks = ordered.enumerated().map { position, pick in
            var pick = pick
            pick.position = position
            return pick
        }
        let videoID = run.video.id
        let projectID = run.projectID
        let order = ordered.map(\.id)
        enqueueTranscriptPickWrite("Could not reorder the picks", batchID: run.batchID) { database in
            try await database.reorderTranscriptPicks(projectID: projectID, videoID: videoID, ids: order)
        }
    }

    /// `ids` is the full set of checked picks; the rest are unchecked.
    func setMiniTranscriptPicksKept(_ ids: Set<Int64>) {
        guard let run = currentTranscriptRun(), let picks = run.transcript?.picks else { return }
        let changed = picks.filter { $0.kept != ids.contains($0.id) }
        guard !changed.isEmpty else { return }
        recordMiniUndo(.transcript)
        miniRuns[.transcript]?.transcript?.picks = picks.map { pick in
            var pick = pick
            pick.kept = ids.contains(pick.id)
            return pick
        }
        let projectID = run.projectID
        let updates = changed.map { ($0.id, ids.contains($0.id)) }
        enqueueTranscriptPickWrite("Could not save the pick", batchID: run.batchID) { database in
            for (id, kept) in updates {
                try await database.setTranscriptPickKept(projectID: projectID, id: id, kept: kept)
            }
        }
    }

    func deleteMiniTranscriptPick(_ id: Int64) {
        guard let run = currentTranscriptRun(), run.transcript?.picks.contains(where: { $0.id == id }) == true else { return }
        recordMiniUndo(.transcript)
        miniRuns[.transcript]?.transcript?.picks.removeAll { $0.id == id }
        let projectID = run.projectID
        enqueueTranscriptPickWrite("Could not delete the pick", batchID: run.batchID) { database in
            try await database.deleteTranscriptPick(projectID: projectID, id: id)
        }
    }

    func deleteAllMiniTranscriptPicks() {
        guard let run = currentTranscriptRun(), run.transcript?.picks.isEmpty == false else { return }
        recordMiniUndo(.transcript)
        miniRuns[.transcript]?.transcript?.picks = []
        let videoID = run.video.id
        let projectID = run.projectID
        let shownSet = TranscriptPickSet.shown(run.transcript?.setKey)
        enqueueTranscriptPickWrite("Could not remove the picks", batchID: run.batchID) { database in
            try await database.deleteTranscriptPicks(projectID: projectID, videoID: videoID, set: shownSet)
        }
    }

    /// Moving to Settings creates one selection per checked pick, in list order, without rendering.
    func recordMiniTranscriptSelections(opening card: MiniWizardFlow.Card = .settings, then: @escaping @MainActor () -> Void = {}) {
        guard let run = currentTranscriptRun(), let transcript = run.transcript,
              transcript.picks.contains(where: \.kept), let database else { return }
        let generation = profileGeneration
        beginWizardSelectionWork(projectID: run.projectID, stage: "Saving transcript picks", options: run.options)
        wizardTask = Task {
            var saved = false
            defer {
                finishWizardSelectionWork(generation: generation)
                if saved, !Task.isCancelled, generation == profileGeneration,
                   activeProjectID == run.projectID, miniRuns[.transcript]?.batchID == run.batchID { then() }
            }
            do {
                _ = try? await transcriptPickSaveTask?.value
                try await sceneEditSaveTask?.value
                try await wizardSelectionSaveTask?.value
                try Task.checkCancellation()
                guard generation == profileGeneration, activeProjectID == run.projectID,
                      miniRuns[.transcript]?.batchID == run.batchID, let picks = miniRuns[.transcript]?.transcript?.picks else { return }
                let reviewedByPick = Dictionary(run.candidates.flatMap { $0.take.plan.clips }.compactMap { clip in
                    clip.miniPickID.map { ($0, clip.brollCuts ?? []) }
                }, uniquingKeysWith: { first, _ in first })
                let candidates = try await database.replaceMiniTranscriptSelections(projectID: run.projectID,
                    videoID: run.video.id, miniBatch: run.batchID, picks: picks, rows: transcript.rows,
                    options: run.options.step1, reviewedCutsByPick: reviewedByPick)
                let updatedPicks = try await database.fetchTranscriptPicks(projectID: run.projectID, videoID: run.video.id)
                guard generation == profileGeneration, activeProjectID == run.projectID,
                      miniRuns[.transcript]?.batchID == run.batchID else { return }
                miniRuns[.transcript]?.transcript?.picks = updatedPicks
                miniRuns[.transcript]?.candidates = candidates
                miniRuns[.transcript]?.selectedSelectionID = candidates.first?.id
                miniRuns[.transcript]?.requestedCard = candidates.isEmpty ? .footage : card
                saved = !candidates.isEmpty
                appendLog(\.wizardLog, ["Express: saved \(candidates.count) transcript picks as selections."])
                // The picks' scenes are new library rows.
                await refreshAllNow()
                await refreshWizardSelections()
            } catch is CancellationError {
                if generation == profileGeneration { appendLog(\.wizardLog, ["Saving transcript picks stopped."]) }
            } catch {
                if generation == profileGeneration { presentError("Could not save the transcript picks", error) }
            }
        }
    }
}
