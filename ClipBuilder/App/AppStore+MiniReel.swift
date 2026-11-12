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
        miniReelSectionOrder = [:]
        guard let database else { return }
        let generation = profileGeneration
        let previous = miniReelSaveTask
        let drops = miniReelHighlightDrops[videoID]
        Task {
            _ = try? await previous?.value
            var items: [MiniReelItem]
            do {
                items = try await database.fetchExpressReelItems(projectID: projectID, videoID: videoID)
            } catch {
                if generation == profileGeneration { presentError("Could not load the reel", error) }
                return
            }
            guard generation == profileGeneration, miniReelKey == key else { return }
            // The video moved to another transcript set while this was read:
            // the rows may still hold the old set's Highlights.
            if drops != miniReelHighlightDrops[videoID] { items.removeAll { $0.kind == .highlights } }
            miniReelItems = items
            miniReelLoaded = true
            reconcileMiniReel()
            loadMiniReelSectionOrder(key: key)
        }
    }

    /// Reads, for every section the reel names, the order its list shows
    /// its items in, without loading the section onto the page: Q&A
    /// exchanges, transcript and fight picks by position, and each
    /// remembered Highlights batch's candidates in their kept order.
    private func loadMiniReelSectionOrder(key: MiniReelKey) {
        guard let database else { return }
        let kinds = Set(miniReelItems.map(\.kind))
        let generation = profileGeneration
        let batches = rememberedHighlightBatches(key: key)
        miniReelSectionRead &+= 1
        let read = miniReelSectionRead
        Task {
            var order: [MiniReelRules.Key: Int] = [:]
            // Sections whose whole list was read: an item of theirs that is
            // not in it names something the source no longer has.
            var whole: Set<MiniWizardFlow.FootageKind> = []
            func record(_ kind: MiniWizardFlow.FootageKind, _ ids: [Int64]) {
                for (index, id) in ids.enumerated() { order[.init(kind: kind, itemID: id)] = index }
            }
            if kinds.contains(.qa),
               let rows = try? await miniTranscriptRows(videoID: key.videoID),
               let scenes = try? await database.fetchScenes(projectID: key.projectID, scope: .active, includeExcluded: true) {
                let videoScenes = scenes.filter { $0.videoID == key.videoID }
                let ids = await Task.detached(priority: .utility) {
                    TranscriptQASections.sections(scenes: videoScenes, rows: rows, labels: [:]).map(\.id)
                }.value
                record(.qa, ids)
                whole.insert(.qa)
            }
            if kinds.contains(.transcript),
               let picks = try? await database.fetchTranscriptPicks(projectID: key.projectID, videoID: key.videoID) {
                record(.transcript, picks.map(\.id))
                whole.insert(.transcript)
            }
            if kinds.contains(.fightMetrics),
               let picks = try? await database.fetchFightPicks(projectID: key.projectID, videoID: key.videoID) {
                record(.fightMetrics, picks.map(\.id))
            }
            if kinds.contains(.highlights) {
                for batch in batches.sorted() {
                    // The same candidates the section restores (a selection needs a take).
                    guard let ids = try? await database.miniSavedCandidates(projectID: key.projectID, miniBatch: batch)
                        .map(\.id) else { continue }
                    let saved = UserDefaults.standard.stringArray(forKey: MiniWizardMemory.highlightOrderKey(batch))?
                        .compactMap(Int64.init) ?? []
                    record(.highlights, WizardPreviewRows.merging(saved, into: ids))
                }
            }
            // A newer read was started since (the transcript set changed
            // again): these lists may be of a set that is no longer in use.
            guard generation == profileGeneration, miniReelKey == key, read == miniReelSectionRead else { return }
            miniReelSectionOrder = order
            // Exchanges and transcript picks belong to a transcript set.
            // After a change of set (now, or while this project was closed)
            // the reel may still list the old set's: removing one there
            // would uncheck a pick of a set that is not on screen. A loaded
            // section reconciles its own items.
            let stale = whole.filter { kind in
                !(miniRuns[kind].map { $0.projectID == key.projectID && $0.video.id == key.videoID && $0.hasFootage } ?? false)
            }
            let items = miniReelItems.filter {
                !stale.contains($0.kind) || order[.init(kind: $0.kind, itemID: $0.itemID)] != nil
            }
            guard miniReelLoaded, items != miniReelItems else { return }
            miniReelItems = items
            saveMiniReel()
        }
    }

    /// The source's transcript set changed: read its sections' lists again
    /// and drop the reel items that are no longer in them.
    func refreshMiniReelSections(videoID: Int64) {
        guard let key = miniReelKey, key.videoID == videoID, miniReelLoaded else { return }
        loadMiniReelSectionOrder(key: key)
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
            // A Highlights run speaks only for its own batch (one per Length):
            // items from another length's batch stay in the reel.
            let known: Set<Int64>? = kind == .highlights ? Set(run.candidates.map(\.id)) : nil
            items = MiniReelRules.reconcile(items, kind: kind, kept: MiniReelRules.kept(run: run), known: known)
        }
        guard items != miniReelItems else { return }
        miniReelItems = items
        saveMiniReel()
    }

    /// Writes after a short pause: a trim drag refreshes snapshots on every
    /// tick, and only the last state needs to reach the table.
    private func saveMiniReel() {
        guard let database, let key = miniReelKey else { return }
        let items = miniReelItems
        let previous = miniReelSaveTask
        previous?.cancel()
        let generation = profileGeneration
        miniReelSaveTask = Task {
            _ = try? await previous?.value
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
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
        guard miniReelLoaded, !isWizardRunning, !isLoadingMiniFootage, !miniEditsBlocked else { return }
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
        guard miniReelLoaded, !isWizardRunning, !isLoadingMiniFootage, !miniEditsBlocked, let key = miniReelKey,
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
            // Only the batch holding the candidate owns it: an item kept at
            // another Length is unkept in that batch's memory.
            if let run, run.candidates.contains(where: { $0.id == item.itemID }) {
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
        let generation = profileGeneration
        let defaults = UserDefaults.standard
        let batches = rememberedHighlightBatches(key: key)
        Task {
            for batch in batches {
                guard let ids = try? await database.fetchWizardSelections(projectID: key.projectID, miniBatch: batch).map(\.id),
                      ids.contains(selectionID), generation == profileGeneration else { continue }
                let kept = Set(defaults.stringArray(forKey: "mini.kept.\(batch)")?.compactMap(Int64.init) ?? ids)
                defaults.set(kept.subtracting([selectionID]).sorted().map(String.init), forKey: "mini.kept.\(batch)")
            }
        }
    }

    /// The Highlights batches remembered for this source, one per Length.
    private func rememberedHighlightBatches(key: MiniReelKey) -> Set<String> {
        let profileName = activeProfile.profileName
        let setKey = transcriptFacts[key.videoID]?.transcriptionKey ?? ""
        return Set(MiniWizardFlow.Length.allCases.compactMap {
            MiniWizardMemory.highlightBatch(profileName: profileName, projectID: key.projectID,
                                            videoID: key.videoID, length: $0, setKey: setKey)
        })
    }

    /// The video moved to another transcript set: its Highlights reel items
    /// name candidates of the set that was left, which Generate could no
    /// longer resolve. They leave the reel (every project's); kept
    /// candidates rejoin when that set's Highlights are loaded again.
    /// The open reel is trimmed at once and saved as usual; only reels that
    /// are not open are trimmed in the table, so a Highlights run restored
    /// right after cannot lose the items it just added.
    func dropMiniReelHighlights(videoID: Int64) {
        miniReelHighlightDrops[videoID, default: 0] &+= 1
        var openProject: Int64?
        // Only a reel that has landed is saved by its owner; one still being
        // read is trimmed in the table like the others, and by its reader.
        if let key = miniReelKey, key.videoID == videoID, miniReelLoaded {
            openProject = key.projectID
            if miniReelItems.contains(where: { $0.kind == .highlights }) {
                miniReelItems.removeAll { $0.kind == .highlights }
                saveMiniReel()
            }
        }
        guard let database else { return }
        // Joins the save queue: a save still waiting for this video's reel
        // (it was open a moment ago) would otherwise write the old
        // Highlights back after the delete, and a reel loaded next waits for
        // it. Nothing in it checks for cancellation, so the next save's
        // cancel of its predecessor cannot skip it.
        let previous = miniReelSaveTask
        miniReelSaveTask = Task {
            _ = try? await previous?.value
            try? await database.deleteExpressReelItems(videoID: videoID, kind: .highlights, exceptProject: openProject)
        }
    }

    /// The saved candidates of the remembered Highlights batches other than
    /// the loaded one that hold reel items, with each batch's kept memory
    /// applied: Generate resolves another Length's reel items from them.
    private func otherHighlightCandidates(key: MiniReelKey) async -> [MiniWizardCandidate] {
        guard let database else { return [] }
        let wanted = Set(miniReelItems.filter { $0.kind == .highlights }.map(\.itemID))
        let loaded = miniRuns[.highlights].flatMap {
            $0.projectID == key.projectID && $0.video.id == key.videoID ? $0.batchID : nil
        }
        guard !wanted.isEmpty else { return [] }
        var result: [MiniWizardCandidate] = []
        for batch in rememberedHighlightBatches(key: key).sorted() where batch != loaded {
            guard var candidates = try? await database.miniSavedCandidates(projectID: key.projectID, miniBatch: batch),
                  candidates.contains(where: { wanted.contains($0.id) }) else { continue }
            if let kept = UserDefaults.standard.stringArray(forKey: "mini.kept.\(batch)") {
                candidates = MiniHighlightReview.settingKept(Set(kept.compactMap(Int64.init)), in: candidates)
            }
            result += candidates.filter { wanted.contains($0.id) }
        }
        return result
    }

    /// The Highlights candidates' kept set; remembered per batch next to
    /// their order, as before the reel.
    func setMiniHighlightsKept(_ kept: Set<Int64>, batchID: String) {
        guard !miniEditsBlocked, let run = miniRuns[.highlights], run.batchID == batchID, !isWizardRunning else { return }
        if kept != MiniHighlightReview.keptIDs(run.candidates) { recordMiniUndo(.highlights) }
        miniRuns[.highlights]?.candidates = MiniHighlightReview.settingKept(kept, in: run.candidates)
        UserDefaults.standard.set(kept.sorted().map(String.init), forKey: "mini.kept.\(batchID)")
    }

    // MARK: - Generate

    /// Generate, Preview or Edit from the Generate panel: one reel from the
    /// whole list in list order. Every section the reel names is loaded
    /// first, then each records its selections in turn, then the render.
    /// `only` limits the render to those sections' items (History's
    /// Re-render makes the opened Highlights batch alone); nil renders the
    /// whole reel. A reel still being read is waited for.
    func generateMiniReel(settings: MiniWizardSettings, flow: MiniWizardFlow, mode: WizardBatchMode = .render,
                          only: Set<MiniWizardFlow.FootageKind>? = nil) {
        guard !isWizardRunning, miniReelGenerateTask == nil, let key = miniReelKey,
              let video = flow.video, key.videoID == video.id, key.projectID == activeProjectID else { return }
        let generation = profileGeneration
        miniReelGenerateTask = Task {
            defer { miniReelGenerateTask = nil }
            // Stops when the source, project or profile changes meanwhile.
            let stillWanted: () -> Bool = { [weak self] in
                guard let self, !Task.isCancelled, generation == self.profileGeneration,
                      self.miniReelKey == key, self.miniFootageVideoID == key.videoID else { return false }
                return true
            }
            while !miniReelLoaded, stillWanted() { try? await Task.sleep(for: .milliseconds(50)) }
            guard stillWanted(), miniReelLoaded else { return }
            let kinds = MiniReelRules.kinds(miniReelItems.filter { only?.contains($0.kind) ?? true })
            guard !kinds.isEmpty else { return }
            await ensureMiniRunsLoaded(kinds: kinds, flow: flow, stillWanted: stillWanted)
            guard stillWanted(), !isWizardRunning else { return }
            let missing = kinds.filter { miniRuns[$0] == nil }
            if !missing.isEmpty {
                appendLog(\.wizardLog, ["Express: \(missing.map(\.label).joined(separator: ", ")) footage is not available; its reel items are left out."])
            }
            let others = kinds.contains(.highlights) ? await otherHighlightCandidates(key: key) : []
            guard stillWanted(), !isWizardRunning else { return }
            recordMiniReelSelections(kinds: kinds.filter { miniRuns[$0] != nil }[...]) { [weak self] in
                guard let self, generation == self.profileGeneration, self.miniReelKey == key else { return }
                self.generateMiniVideos(settings: settings, flow: flow, mode: mode, only: only, otherHighlights: others)
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
