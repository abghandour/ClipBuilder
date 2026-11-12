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
        selectMiniFootage(flow: flow)
        guard miniRuns[.highlights] == nil, !isLoadingMiniFootage else { return }
        let profileName = activeProfile.profileName
        let setKey = transcriptFacts[video.id]?.transcriptionKey ?? ""
        let length = flow.length
        guard let batch = MiniWizardMemory.highlightBatch(profileName: profileName, projectID: projectID,
            videoID: video.id, length: length, setKey: setKey) else { return }
        let forget = {
            MiniWizardMemory.forgetHighlightBatch(batch, profileName: profileName, projectID: projectID,
                                                  videoID: video.id, length: length, setKey: setKey)
        }
        let generation = profileGeneration
        var options = WizardOptions()
        options.projectID = projectID
        options.formatPreset = flow.isPodcastOrInterview ? ReelRecipe.podcastHighlights.id : "custom"
        options.sourceVideoPaths = [video.path ?? ""]
        options.sourcesRestricted = true
        options.manualBRoll = true
        options.targetDurationSeconds = flow.length.seconds
        options.critiqueLoop = false
        let loadID = beginMiniFootageLoad(stage: "Restoring Express footage")
        miniFootageTask = Task {
            defer { finishMiniFootageLoad(loadID) }
            do {
                var candidates = try await database.miniSavedCandidates(projectID: projectID, miniBatch: batch)
                guard !Task.isCancelled, generation == profileGeneration, activeProjectID == projectID else { return }
                guard !candidates.isEmpty else { forget(); return }
                if let kept = UserDefaults.standard.stringArray(forKey: "mini.kept.\(batch)") {
                    candidates = MiniHighlightReview.settingKept(Set(kept.compactMap(Int64.init)), in: candidates)
                }
                if let order = UserDefaults.standard.stringArray(forKey: MiniWizardMemory.highlightOrderKey(batch)) {
                    let ids = WizardPreviewRows.merging(order.compactMap(Int64.init), into: candidates.map(\.id))
                    let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    candidates = ids.compactMap { byID[$0] }
                }
                guard miniFootageLoadID == loadID else { return }
                miniRuns[.highlights] = MiniWizardRun(projectID: projectID, video: video, footageKind: .highlights,
                    length: flow.length, batchID: batch, candidates: candidates, options: options,
                    selectedSelectionID: candidates.first?.id)
            } catch is CancellationError {
                // Switching source or tab must not remove the remembered batch.
            } catch {
                guard !Task.isCancelled, miniFootageLoadID == loadID, generation == profileGeneration else { return }
                forget()
                presentError("Could not restore Express footage", error)
            }
        }
    }
}
