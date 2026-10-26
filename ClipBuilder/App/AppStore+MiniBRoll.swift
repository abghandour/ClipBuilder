import Foundation

extension AppStore {
    func setMiniBRoll(_ cuts: [BRollCut], piece: MiniBRollRules.Piece, batchID: String) {
        guard let run = miniRun, run.batchID == batchID, !isWizardRunning,
              let candidate = run.candidates.first(where: { $0.id == piece.id.selectionID && $0.take.id == piece.takeID }),
              candidate.take.plan.clips.indices.contains(piece.id.clipIndex) else { return }
        var plan = candidate.take.plan
        plan.clips[piece.id.clipIndex].brollCuts = MiniBRollRules.retained(cuts, in: piece.range)
        saveMiniCandidatePlan(plan, selectionID: candidate.id, takeID: candidate.take.id)
    }

    func removeAllMiniBRoll(batchID: String) {
        guard let run = miniRun, run.batchID == batchID else { return }
        for candidate in run.candidates {
            var plan = candidate.take.plan
            for index in plan.clips.indices { plan.clips[index].brollCuts = [] }
            saveMiniCandidatePlan(plan, selectionID: candidate.id, takeID: candidate.take.id)
        }
    }
}

extension AppStore {
    func restoreMiniHighlights(flow: MiniWizardFlow) {
        guard let video = flow.video, let projectID = activeProjectID, let database, !isWizardRunning else { return }
        let key = MiniWizardMemory.batchKey(profileName: activeProfile.profileName, projectID: projectID,
            videoID: video.id, kind: .highlights, length: flow.length)
        guard let batch = UserDefaults.standard.string(forKey: key) else { return }
        let generation = profileGeneration
        var options = WizardOptions()
        options.projectID = projectID
        options.formatPreset = flow.isPodcastOrInterview ? ReelRecipe.podcastHighlights.id : "custom"
        options.sourceVideoPaths = [video.path ?? ""]
        options.sourcesRestricted = true
        options.manualBRoll = true
        options.targetDurationSeconds = flow.length.seconds
        options.critiqueLoop = false
        beginWizardSelectionWork(projectID: projectID, stage: "Restoring Express footage", options: options)
        wizardTask = Task {
            defer { finishWizardSelectionWork(generation: generation) }
            do {
                var candidates = try await database.miniSavedCandidates(projectID: projectID, miniBatch: batch)
                guard !Task.isCancelled, generation == profileGeneration, activeProjectID == projectID else { return }
                guard !candidates.isEmpty else { UserDefaults.standard.removeObject(forKey: key); return }
                if let kept = UserDefaults.standard.stringArray(forKey: "mini.kept.\(batch)") {
                    candidates = MiniHighlightReview.settingKept(Set(kept.compactMap(Int64.init)), in: candidates)
                }
                miniRun = MiniWizardRun(projectID: projectID, video: video, footageKind: .highlights,
                    length: flow.length, batchID: batch, candidates: candidates, options: options,
                    selectedSelectionID: candidates.first?.id)
            } catch {
                guard generation == profileGeneration else { return }
                UserDefaults.standard.removeObject(forKey: key)
                presentError("Could not restore Express footage", error)
            }
        }
    }
}
