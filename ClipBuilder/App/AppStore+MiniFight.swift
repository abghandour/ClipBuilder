import Foundation

/// Express Fight metrics: picks are stored per video as the user adds them;
/// moving to Settings turns them into selections in list order.
extension AppStore {
    /// Load the video's scored actions, fighter names and saved picks.
    func loadMiniFight(flow: MiniWizardFlow) {
        guard let video = flow.video, let database, let projectID = activeProjectID, !isWizardRunning else { return }
        let generation = profileGeneration
        guard video.isPresent else { presentError(VideoRecord.notPresentReason); return }
        var options = WizardOptions()
        options.projectID = projectID
        options.sourceVideoPaths = [video.path ?? ""]
        options.sourcesRestricted = true
        options.formatPreset = "custom"
        options.critiqueLoop = false
        options.workflow = .automatic
        beginWizardSelectionWork(projectID: projectID, stage: "Loading fight actions", options: options)
        wizardTask = Task {
            defer { finishWizardSelectionWork(generation: generation) }
            do {
                _ = try? await fightPickSaveTask?.value
                try Task.checkCancellation()
                let picks = try await database.fetchFightPicks(videoID: video.id)
                guard generation == profileGeneration, activeProjectID == projectID else { return }
                let events = fightEvents[video.id] ?? []
                let actions = MiniWizardFightRules.actions(events: events, duration: video.duration)
                let names = Dictionary(uniqueKeysWithValues: people.map { ($0.key, $0.displayName) })
                miniRun = MiniWizardRun(projectID: projectID, video: video, footageKind: .fightMetrics,
                    length: .automatic, batchID: UUID().uuidString, candidates: [], options: options,
                    fight: MiniWizardFight(actions: actions, picks: picks, names: names))
                appendLog(\.wizardLog, ["Express: \(actions.count) fight actions, \(picks.count) saved picks."])
            } catch is CancellationError {
                if generation == profileGeneration { appendLog(\.wizardLog, ["Loading fight actions stopped."]) }
            } catch {
                if generation == profileGeneration { presentError("Could not load the fight actions", error) }
            }
        }
    }

    private func currentFightRun() -> MiniWizardRun? {
        guard let run = miniRun, run.footageKind == .fightMetrics, run.projectID == activeProjectID,
              run.fight != nil, !isWizardRunning else { return nil }
        return run
    }

    /// Serial writes keep positions and ranges in the order the user made them.
    private func enqueueFightPickWrite(_ context: String, batchID: String,
                                       write: @escaping @Sendable (Database) async throws -> Void) {
        guard let database else { return }
        let previous = fightPickSaveTask
        let generation = profileGeneration
        fightPickSaveTask = Task {
            _ = try? await previous?.value
            do {
                try await write(database)
            } catch {
                if generation == profileGeneration { presentError(context, error) }
                throw error
            }
        }
    }

    /// One pick per unit, in time order.
    func addMiniFightPicks(_ units: [(range: ClosedRange<Double>, eventIDs: [Int64])]) {
        guard let run = currentFightRun(), !units.isEmpty, let database else { return }
        let videoID = run.video.id
        let batchID = run.batchID
        let previous = fightPickSaveTask
        let generation = profileGeneration
        let units = units.filter { $0.range.upperBound > $0.range.lowerBound }
        fightPickSaveTask = Task {
            _ = try? await previous?.value
            var added: [FightPick] = []
            do {
                for unit in units {
                    added.append(try await database.addFightPick(videoID: videoID, start: unit.range.lowerBound,
                                                                 end: unit.range.upperBound, eventIDs: unit.eventIDs))
                }
            } catch {
                if generation == profileGeneration { presentError("Could not add the pick", error) }
                throw error
            }
            guard generation == profileGeneration, miniRun?.batchID == batchID else { return }
            miniRun?.fight?.picks.append(contentsOf: added)
        }
    }

    func setMiniFightPickRange(_ id: Int64, start: Double, end: Double) {
        guard let run = currentFightRun(), end > start,
              let index = run.fight?.picks.firstIndex(where: { $0.id == id }) else { return }
        miniRun?.fight?.picks[index].start = start
        miniRun?.fight?.picks[index].end = end
        enqueueFightPickWrite("Could not save the pick", batchID: run.batchID) { database in
            try await database.setFightPickRange(id: id, start: start, end: end)
        }
    }

    /// `ids` is the full list in its new order.
    func reorderMiniFightPicks(_ ids: [Int64]) {
        guard let run = currentFightRun(), let picks = run.fight?.picks else { return }
        let byID = Dictionary(uniqueKeysWithValues: picks.map { ($0.id, $0) })
        let ordered = ids.compactMap { byID[$0] } + picks.filter { !ids.contains($0.id) }
        guard ordered.map(\.id) != picks.map(\.id) else { return }
        miniRun?.fight?.picks = ordered.enumerated().map { position, pick in
            var pick = pick
            pick.position = position
            return pick
        }
        let videoID = run.video.id
        let order = ordered.map(\.id)
        enqueueFightPickWrite("Could not reorder the picks", batchID: run.batchID) { database in
            try await database.reorderFightPicks(videoID: videoID, ids: order)
        }
    }

    func deleteMiniFightPick(_ id: Int64) {
        guard let run = currentFightRun(), run.fight?.picks.contains(where: { $0.id == id }) == true else { return }
        miniRun?.fight?.picks.removeAll { $0.id == id }
        enqueueFightPickWrite("Could not delete the pick", batchID: run.batchID) { database in
            try await database.deleteFightPick(id: id)
        }
    }

    /// Moving to Settings creates one selection per pick, in list order, without rendering.
    func recordMiniFightSelections() {
        guard let run = currentFightRun(), let fight = run.fight, !fight.picks.isEmpty, let database else { return }
        let generation = profileGeneration
        beginWizardSelectionWork(projectID: run.projectID, stage: "Saving fight picks", options: run.options)
        wizardTask = Task {
            defer { finishWizardSelectionWork(generation: generation) }
            do {
                _ = try? await fightPickSaveTask?.value
                try Task.checkCancellation()
                guard generation == profileGeneration, activeProjectID == run.projectID,
                      miniRun?.batchID == run.batchID, let picks = miniRun?.fight?.picks else { return }
                let candidates = try await database.replaceMiniFightSelections(projectID: run.projectID,
                    videoID: run.video.id, miniBatch: run.batchID, picks: picks, actions: fight.actions,
                    names: fight.names, options: run.options.step1)
                guard generation == profileGeneration, activeProjectID == run.projectID,
                      miniRun?.batchID == run.batchID else { return }
                miniRun?.candidates = candidates
                miniRun?.selectedSelectionID = candidates.first?.id
                miniRun?.requestedCard = candidates.isEmpty ? .footage : .settings
                appendLog(\.wizardLog, ["Express: saved \(candidates.count) fight picks as selections."])
                // The picks' scenes are new library rows.
                await refreshAllNow()
                await refreshWizardSelections()
            } catch is CancellationError {
                if generation == profileGeneration { appendLog(\.wizardLog, ["Saving fight picks stopped."]) }
            } catch {
                if generation == profileGeneration { presentError("Could not save the fight picks", error) }
            }
        }
    }
}
