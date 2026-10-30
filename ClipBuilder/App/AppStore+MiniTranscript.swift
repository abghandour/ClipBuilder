import Foundation

/// Express Transcript mode: picks are stored per video as the user adds them;
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
                let rows = try await miniTranscriptRows(videoID: video.id)
                let picks = try await database.fetchTranscriptPicks(videoID: video.id)
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
                        speakerSpans: TranscriptSpeakers.spans(turns: namedTurns, roster: speakers.roster))
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

    private func currentTranscriptRun() -> MiniWizardRun? {
        guard let run = miniRun, run.footageKind == .transcript, run.projectID == activeProjectID,
              run.transcript != nil, !isWizardRunning else { return nil }
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
        let videoID = run.video.id
        let batchID = run.batchID
        let previous = transcriptPickSaveTask
        let generation = profileGeneration
        guard let database else { return }
        transcriptPickSaveTask = Task {
            _ = try? await previous?.value
            let pick: TranscriptPick
            do {
                pick = try await database.addTranscriptPick(videoID: videoID, start: range.lowerBound, end: range.upperBound)
            } catch {
                if generation == profileGeneration { presentError("Could not add the pick", error) }
                throw error
            }
            guard generation == profileGeneration, miniRuns[.transcript]?.batchID == batchID else { return }
            miniRuns[.transcript]?.transcript?.picks.append(pick)
        }
    }

    func setMiniTranscriptPickRange(_ id: Int64, start: Double, end: Double) {
        guard let run = currentTranscriptRun(), end > start,
              let index = run.transcript?.picks.firstIndex(where: { $0.id == id }) else { return }
        miniRuns[.transcript]?.transcript?.picks[index].start = start
        miniRuns[.transcript]?.transcript?.picks[index].end = end
        enqueueTranscriptPickWrite("Could not save the pick", batchID: run.batchID) { database in
            try await database.setTranscriptPickRange(id: id, start: start, end: end)
        }
    }

    /// `ids` is the full list in its new order.
    func reorderMiniTranscriptPicks(_ ids: [Int64]) {
        guard let run = currentTranscriptRun(), let picks = run.transcript?.picks else { return }
        let byID = Dictionary(uniqueKeysWithValues: picks.map { ($0.id, $0) })
        let ordered = ids.compactMap { byID[$0] } + picks.filter { !ids.contains($0.id) }
        guard ordered.map(\.id) != picks.map(\.id) else { return }
        miniRuns[.transcript]?.transcript?.picks = ordered.enumerated().map { position, pick in
            var pick = pick
            pick.position = position
            return pick
        }
        let videoID = run.video.id
        let order = ordered.map(\.id)
        enqueueTranscriptPickWrite("Could not reorder the picks", batchID: run.batchID) { database in
            try await database.reorderTranscriptPicks(videoID: videoID, ids: order)
        }
    }

    func deleteMiniTranscriptPick(_ id: Int64) {
        guard let run = currentTranscriptRun(), run.transcript?.picks.contains(where: { $0.id == id }) == true else { return }
        miniRuns[.transcript]?.transcript?.picks.removeAll { $0.id == id }
        enqueueTranscriptPickWrite("Could not delete the pick", batchID: run.batchID) { database in
            try await database.deleteTranscriptPick(id: id)
        }
    }

    func deleteAllMiniTranscriptPicks() {
        guard let run = currentTranscriptRun(), run.transcript?.picks.isEmpty == false else { return }
        miniRuns[.transcript]?.transcript?.picks = []
        let videoID = run.video.id
        enqueueTranscriptPickWrite("Could not remove the picks", batchID: run.batchID) { database in
            try await database.deleteTranscriptPicks(videoID: videoID)
        }
    }

    /// Moving to Settings creates one selection per pick, in list order, without rendering.
    func recordMiniTranscriptSelections(opening card: MiniWizardFlow.Card = .settings, then: @escaping @MainActor () -> Void = {}) {
        guard let run = currentTranscriptRun(), let transcript = run.transcript,
              !transcript.picks.isEmpty, let database else { return }
        let generation = profileGeneration
        beginWizardSelectionWork(projectID: run.projectID, stage: "Saving transcript picks", options: run.options)
        wizardTask = Task {
            var saved = false
            defer {
                finishWizardSelectionWork(generation: generation)
                if saved, !Task.isCancelled, generation == profileGeneration,
                   activeProjectID == run.projectID, miniRun?.batchID == run.batchID { then() }
            }
            do {
                _ = try? await transcriptPickSaveTask?.value
                try await sceneEditSaveTask?.value
                try await wizardSelectionSaveTask?.value
                try Task.checkCancellation()
                guard generation == profileGeneration, activeProjectID == run.projectID,
                      miniRun?.batchID == run.batchID, let picks = miniRun?.transcript?.picks else { return }
                let reviewedByPick = Dictionary(run.candidates.flatMap { $0.take.plan.clips }.compactMap { clip in
                    clip.miniPickID.map { ($0, clip.brollCuts ?? []) }
                }, uniquingKeysWith: { first, _ in first })
                let candidates = try await database.replaceMiniTranscriptSelections(projectID: run.projectID,
                    videoID: run.video.id, miniBatch: run.batchID, picks: picks, rows: transcript.rows,
                    options: run.options.step1, reviewedCutsByPick: reviewedByPick)
                let updatedPicks = try await database.fetchTranscriptPicks(videoID: run.video.id)
                guard generation == profileGeneration, activeProjectID == run.projectID,
                      miniRun?.batchID == run.batchID else { return }
                miniRun?.transcript?.picks = updatedPicks
                miniRun?.candidates = candidates
                miniRun?.selectedSelectionID = candidates.first?.id
                miniRun?.requestedCard = candidates.isEmpty ? .footage : card
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
