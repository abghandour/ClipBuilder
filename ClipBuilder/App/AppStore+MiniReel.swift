import Foundation

/// The project and source video a reel belongs to.
nonisolated struct MiniReelKey: Hashable, Sendable {
    var projectID: Int64
    var videoID: Int64
}

/// The Express reel (docs/Express-Reel-List-Plan.md): one ordered list of
/// everything selected across the Footage sections. Membership is owned by
/// each section (qa_picks, transcript_picks.kept, fight_picks, the Highlights
/// kept memory); the reel mirrors it whenever `miniRuns` changes and keeps
/// the order and a snapshot per item in `express_reel_items`.
extension AppStore {
    /// Reads the reel for this source when it changes; nothing is written
    /// until the read has landed.
    func loadMiniReel(projectID: Int64, videoID: Int64) {
        let key = MiniReelKey(projectID: projectID, videoID: videoID)
        guard miniReelKey != key else { return }
        miniReelKey = key
        miniReelLoaded = false
        miniReelItems = []
        guard let database else { return }
        let generation = profileGeneration
        let previous = miniReelSaveTask
        Task {
            _ = try? await previous?.value
            let items: [MiniReelItem]
            do {
                items = try await database.fetchExpressReelItems(projectID: projectID, videoID: videoID)
            } catch {
                if generation == profileGeneration { presentError("Could not load the reel", error) }
                return
            }
            guard generation == profileGeneration, miniReelKey == key else { return }
            miniReelItems = items
            miniReelLoaded = true
            reconcileMiniReel()
        }
    }

    func clearMiniReel() {
        miniReelGenerateTask?.cancel()
        miniReelGenerateTask = nil
        miniReelReveal = nil
        miniReelKey = nil
        miniReelLoaded = false
        miniReelItems = []
    }

    /// Brings the reel in line with every loaded section of its source:
    /// unkept items leave, newly kept ones join at the end, snapshots refresh.
    func reconcileMiniReel() {
        guard miniReelLoaded, let key = miniReelKey else { return }
        var items = miniReelItems
        for (kind, run) in miniRuns where run.projectID == key.projectID && run.video.id == key.videoID && run.hasFootage {
            items = MiniReelRules.reconcile(items, kind: kind, kept: MiniReelRules.kept(run: run))
        }
        guard items != miniReelItems else { return }
        miniReelItems = items
        saveMiniReel()
    }

    private func saveMiniReel() {
        guard let database, let key = miniReelKey else { return }
        let items = miniReelItems
        let previous = miniReelSaveTask
        let generation = profileGeneration
        miniReelSaveTask = Task {
            _ = try? await previous?.value
            do {
                try await database.replaceExpressReelItems(projectID: key.projectID, videoID: key.videoID, items: items)
            } catch {
                if generation == profileGeneration { presentError("Could not save the reel", error) }
                throw error
            }
        }
    }

    /// A List drop: `clipIDs` is the whole list in its new order.
    func reorderMiniReel(_ clipIDs: [String]) {
        guard miniReelLoaded, !isWizardRunning, !isLoadingMiniFootage else { return }
        let items = MiniReelRules.reordered(miniReelItems, clipIDs: clipIDs)
        guard items != miniReelItems else { return }
        miniReelItems = items
        saveMiniReel()
    }

    /// Delete on a List row: the item leaves the reel and is unselected in
    /// its section (a fight pick, which has no Keep box, is deleted).
    func removeMiniReelItem(clipID: String) {
        // Not while a section loads: a load that already read its picks
        // would publish the item again and the reconcile would restore it.
        guard miniReelLoaded, !isWizardRunning, !isLoadingMiniFootage, let key = miniReelKey,
              let item = MiniReelRules.item(miniReelItems, clipID: clipID), let database else { return }
        let run = miniRuns[item.kind].flatMap { $0.projectID == key.projectID && $0.video.id == key.videoID ? $0 : nil }
        let generation = profileGeneration
        switch item.kind {
        case .qa:
            if let run, let qa = run.qa {
                setMiniQAKept(qa.kept.subtracting([item.itemID]), batchID: run.batchID)
            } else {
                let previous = qaPickSaveTask
                qaPickSaveTask = Task {
                    _ = try? await previous?.value
                    do {
                        try await database.applyQAPickDelta(projectID: key.projectID, videoID: key.videoID,
                                                            inserted: [], deleted: [item.itemID])
                    } catch {
                        if generation == profileGeneration { presentError("Could not save the kept exchanges", error) }
                        throw error
                    }
                }
            }
        case .transcript:
            if let picks = run?.transcript?.picks {
                setMiniTranscriptPicksKept(Set(picks.filter(\.kept).map(\.id)).subtracting([item.itemID]))
            } else {
                let previous = transcriptPickSaveTask
                transcriptPickSaveTask = Task {
                    _ = try? await previous?.value
                    do {
                        try await database.setTranscriptPickKept(projectID: key.projectID, id: item.itemID, kept: false)
                    } catch {
                        if generation == profileGeneration { presentError("Could not save the pick", error) }
                        throw error
                    }
                }
            }
        case .fightMetrics:
            if run?.fight != nil {
                deleteMiniFightPick(item.itemID)
            } else {
                let previous = fightPickSaveTask
                fightPickSaveTask = Task {
                    _ = try? await previous?.value
                    do {
                        try await database.deleteFightPick(projectID: key.projectID, id: item.itemID)
                    } catch {
                        if generation == profileGeneration { presentError("Could not delete the pick", error) }
                        throw error
                    }
                }
            }
        case .highlights:
            if let run {
                setMiniHighlightsKept(MiniHighlightReview.keptIDs(run.candidates).subtracting([item.itemID]),
                                      batchID: run.batchID)
            } else {
                unkeepUnloadedHighlight(item.itemID, key: key)
            }
        }
        // A loaded section already dropped the row through the reconcile.
        let items = MiniReelRules.removing(miniReelItems, clipID: clipID)
        guard items != miniReelItems else { return }
        miniReelItems = items
        saveMiniReel()
    }

    /// Remove All on the List: every item leaves the reel and its section.
    func removeAllMiniReelItems() {
        for item in miniReelItems { removeMiniReelItem(clipID: item.clipID) }
    }

    /// Select on a List row: asks the page to open the item's section and
    /// select it there.
    func revealMiniReelItem(clipID: String) {
        guard let item = MiniReelRules.item(miniReelItems, clipID: clipID) else { return }
        miniReelReveal = item.key
    }

    /// Delete on a Highlights item whose section is not loaded: the kept
    /// memory of the remembered batch holding that candidate loses it, so a
    /// later restore does not bring it back.
    private func unkeepUnloadedHighlight(_ selectionID: Int64, key: MiniReelKey) {
        guard let database else { return }
        let profileName = activeProfile.profileName
        let generation = profileGeneration
        let defaults = UserDefaults.standard
        let batches = MiniWizardFlow.Length.allCases.compactMap {
            defaults.string(forKey: MiniWizardMemory.batchKey(profileName: profileName, projectID: key.projectID,
                                                               videoID: key.videoID, kind: .highlights, length: $0))
        }
        Task {
            for batch in Set(batches) {
                guard let ids = try? await database.fetchWizardSelections(projectID: key.projectID, miniBatch: batch).map(\.id),
                      ids.contains(selectionID), generation == profileGeneration else { continue }
                let kept = Set(defaults.stringArray(forKey: "mini.kept.\(batch)")?.compactMap(Int64.init) ?? ids)
                defaults.set(kept.subtracting([selectionID]).sorted().map(String.init), forKey: "mini.kept.\(batch)")
            }
        }
    }

    /// The Highlights candidates' kept set; remembered per batch next to
    /// their order, as before the reel.
    func setMiniHighlightsKept(_ kept: Set<Int64>, batchID: String) {
        guard let run = miniRuns[.highlights], run.batchID == batchID, !isWizardRunning else { return }
        miniRuns[.highlights]?.candidates = MiniHighlightReview.settingKept(kept, in: run.candidates)
        UserDefaults.standard.set(kept.sorted().map(String.init), forKey: "mini.kept.\(batchID)")
    }

    // MARK: - Generate

    /// Generate, Preview or Edit from the Generate panel: one reel from the
    /// whole list in list order. Every section the reel names is loaded
    /// first, then each records its selections in turn, then the render.
    func generateMiniReel(settings: MiniWizardSettings, flow: MiniWizardFlow, mode: WizardBatchMode = .render) {
        guard !isWizardRunning, miniReelGenerateTask == nil, miniReelLoaded, let key = miniReelKey,
              let video = flow.video, key.videoID == video.id, key.projectID == activeProjectID,
              !miniReelItems.isEmpty else { return }
        let kinds = MiniReelRules.kinds(miniReelItems)
        let generation = profileGeneration
        miniReelGenerateTask = Task {
            defer { miniReelGenerateTask = nil }
            // Stops when the source, project or profile changes meanwhile.
            let stillWanted: () -> Bool = { [weak self] in
                guard let self, !Task.isCancelled, generation == self.profileGeneration,
                      self.miniReelKey == key, self.miniFootageVideoID == key.videoID else { return false }
                return true
            }
            await ensureMiniRunsLoaded(kinds: kinds, flow: flow, stillWanted: stillWanted)
            guard stillWanted(), !isWizardRunning else { return }
            let missing = kinds.filter { miniRuns[$0] == nil }
            if !missing.isEmpty {
                appendLog(\.wizardLog, ["Express: \(missing.map(\.label).joined(separator: ", ")) footage is not available; its reel items are left out."])
            }
            recordMiniReelSelections(kinds: kinds.filter { miniRuns[$0] != nil }[...]) { [weak self] in
                guard let self, generation == self.profileGeneration, self.miniReelKey == key else { return }
                self.generateMiniVideos(settings: settings, flow: flow, mode: mode)
            }
        }
    }

    /// Loads the sections the reel names that are not loaded yet, one at a
    /// time (the footage loader runs one load at a time), then returns the
    /// page to the section it was showing.
    private func ensureMiniRunsLoaded(kinds: [MiniWizardFlow.FootageKind], flow: MiniWizardFlow,
                                      stillWanted: () -> Bool) async {
        for kind in kinds where miniRuns[kind] == nil {
            if let task = miniFootageTask { await task.value }
            guard stillWanted(), miniRuns[kind] == nil, !isWizardRunning else { continue }
            var kindFlow = flow
            kindFlow.footageKind = kind
            guard kindFlow.effectiveFootageKind == kind else { continue }
            if kind == .highlights { restoreMiniHighlights(flow: kindFlow) } else { generateMiniFootage(flow: kindFlow) }
            if let task = miniFootageTask { await task.value }
        }
        if stillWanted() { selectMiniFootage(flow: flow) }
    }

    /// Q&A, Transcript and Fight picks become selections section by section;
    /// Highlights candidates already are.
    private func recordMiniReelSelections(kinds: ArraySlice<MiniWizardFlow.FootageKind>,
                                          then: @escaping @MainActor () -> Void) {
        guard let kind = kinds.first else { then(); return }
        let rest = kinds.dropFirst()
        let next: @MainActor () -> Void = { [weak self] in self?.recordMiniReelSelections(kinds: rest, then: then) }
        guard let run = miniRuns[kind], run.keptCount > 0 else { next(); return }
        switch kind {
        case .qa: recordMiniQASelections(then: next)
        case .transcript: recordMiniTranscriptSelections(then: next)
        case .fightMetrics: recordMiniFightSelections(then: next)
        case .highlights: next()
        }
    }
}
