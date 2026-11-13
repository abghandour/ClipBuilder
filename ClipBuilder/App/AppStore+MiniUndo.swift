import Foundation

/// Undo and Redo for the manual changes in an Express Footage section
/// (Transcript, Q&A, Highlights). Each manual change records the section as
/// it was; stepping back restores that through the same store actions that
/// made the change, so it is saved like any other edit.
extension AppStore {
    /// The section as it stands, in the form Undo compares and restores.
    func miniUndoSnapshot(_ kind: MiniWizardFlow.FootageKind) -> MiniUndoSnapshot? {
        guard let run = miniRuns[kind] else { return nil }
        let reelOrder = miniReelItems.map(\.key)
        switch kind {
        case .transcript:
            return run.transcript.map { .transcript(picks: $0.picks, reelOrder: reelOrder) }
        case .qa:
            guard let qa = run.qa else { return nil }
            return .qa(.init(kept: qa.kept, order: qa.keptOrder,
                             ranges: Dictionary(qa.sections.map { ($0.id, $0.range) }, uniquingKeysWith: { first, _ in first })),
                       reelOrder: reelOrder)
        case .highlights:
            var plans: [Int64: MiniUndoSnapshot.Highlights.Plan] = [:]
            for candidate in run.candidates {
                plans[candidate.id] = .init(takeID: candidate.take.id,
                                            revision: miniPlanRevisions[candidate.take.id, default: 0],
                                            plan: candidate.take.plan)
            }
            return .highlights(.init(kept: MiniHighlightReview.keptIDs(run.candidates),
                                     order: run.candidates.map(\.id), plans: plans), reelOrder: reelOrder)
        case .fightMetrics:
            return nil
        }
    }

    /// Called by a manual change, before it changes anything. The first
    /// call keeps the section as it was; every call then waits for the
    /// change's own save (which is also when an added pick or a Q&A trim
    /// reaches the section) and keeps the state it settled in.
    func recordMiniUndo(_ kind: MiniWizardFlow.FootageKind) {
        guard !isMiniUndoing, let batchID = miniRuns[kind]?.batchID, let current = miniUndoSnapshot(kind) else { return }
        // With no earlier change still settling, the section should stand
        // where the history says. If it does not, something changed it
        // without recording (a regenerate, a change this was not told of):
        // start over rather than let Undo jump past that change.
        if miniUndoSettlesPending == 0, let expected = miniUndoStacks[batchID]?.current, expected != current {
            miniUndoStacks[batchID]?.reset(to: current)
        }
        pruneMiniUndoStacks(keeping: batchID)
        miniUndoStacks[batchID, default: MiniUndoStack()].begin(current)
        if let run = miniRuns[kind] { miniUndoStackSources[batchID] = MiniReelKey(projectID: run.projectID, videoID: run.video.id) }
        // Called before the change lands: the reel as it stands is what
        // Undo of this change must put back.
        miniUndoStacks[batchID]?.refreshPlacement(current)
        let previous = miniUndoSettleTask
        let generation = profileGeneration
        miniUndoSettlesPending += 1
        miniUndoSettleTask = Task {
            defer { miniUndoSettlesPending -= 1 }
            // This runs once the calling change has queued its save.
            let saves = [transcriptPickSaveTask, qaPickSaveTask, sceneEditSaveTask, wizardSelectionSaveTask]
            await previous?.value
            for save in saves { _ = try? await save?.value }
            guard generation == profileGeneration, miniRuns[kind]?.batchID == batchID,
                  let settled = miniUndoSnapshot(kind) else { return }
            miniUndoStacks[batchID]?.commit(settled)
        }
    }

    /// Histories are per recording and section and last while the app is
    /// open; past this many, the ones not on screen go.
    private static let miniUndoStackLimit = 24

    private func pruneMiniUndoStacks(keeping batchID: String) {
        guard miniUndoStacks.count >= Self.miniUndoStackLimit else { return }
        let loaded = Set(miniRuns.values.map(\.batchID)).union([batchID])
        miniUndoStacks = miniUndoStacks.filter { loaded.contains($0.key) }
        miniUndoStackSources = miniUndoStackSources.filter { loaded.contains($0.key) }
    }

    /// A Team Sync pull changed picks or scenes: every history ends, also
    /// those of recordings not on screen, since stepping back in one would
    /// undo a teammate (or delete their pick).
    func forgetAllMiniUndo() {
        miniUndoStacks = [:]
        miniUndoStackSources = [:]
    }

    /// A Q&A exchange trimmed by hand in the Express Footage card.
    func setMiniQASceneRange(_ scene: SceneRecord, start: Double, end: Double) {
        guard !miniEditsBlocked else { return }
        recordMiniUndo(.qa)
        setSceneEditRange(scene, start: start, end: end)
    }

    /// True while Undo or Redo is putting a section back and the caller is
    /// the user, not that restore: every manual change to the Express
    /// footage and reel list waits it out, or the restore would overwrite
    /// it in memory while its own save still reached the database.
    var miniEditsBlocked: Bool { isMiniUndoing && !isRestoringMiniUndo }

    /// Not during a Team Sync: its pull writes rows the screen has not
    /// shown yet, and a step taken then would overwrite a teammate's change.
    func canUndoMini(_ kind: MiniWizardFlow.FootageKind) -> Bool {
        !teamSync.syncing && (miniRuns[kind].flatMap { miniUndoStacks[$0.batchID] }?.canUndo ?? false)
    }

    func canRedoMini(_ kind: MiniWizardFlow.FootageKind) -> Bool {
        !teamSync.syncing && (miniRuns[kind].flatMap { miniUndoStacks[$0.batchID] }?.canRedo ?? false)
    }

    func undoMini(_ kind: MiniWizardFlow.FootageKind) { stepMiniUndo(kind, redo: false) }
    func redoMini(_ kind: MiniWizardFlow.FootageKind) { stepMiniUndo(kind, redo: true) }

    private func settleMiniSaves() async {
        _ = try? await transcriptPickSaveTask?.value
        _ = try? await qaPickSaveTask?.value
        _ = try? await sceneEditSaveTask?.value
        _ = try? await wizardSelectionSaveTask?.value
    }

    private func stepMiniUndo(_ kind: MiniWizardFlow.FootageKind, redo: Bool) {
        guard !isWizardRunning, !isMiniUndoing, !teamSync.syncing, miniFootageKind == kind,
              let batchID = miniRuns[kind]?.batchID else { return }
        let generation = profileGeneration
        // The section's controls are disabled until the restore has been
        // saved and shown, so no edit can land in the middle of it.
        isMiniUndoing = true
        miniUndoStepTask = Task {
            defer { isMiniUndoing = false }
            await miniUndoSettleTask?.value
            await settleMiniSaves()
            // No await between this check and the restore's writes being
            // queued, so a sync cannot start in between unseen.
            guard generation == profileGeneration, !isWizardRunning, !teamSync.syncing, miniFootageKind == kind,
                  miniRuns[kind]?.batchID == batchID, let stack = miniUndoStacks[batchID],
                  let current = miniUndoSnapshot(kind) else { return }
            // The section is not where the history left it: a step would
            // also throw away whatever changed it. The history starts over.
            guard stack.current == current else {
                miniUndoStacks[batchID]?.reset(to: current)
                return
            }
            guard let target = redo ? stack.redoTarget : stack.undoTarget else { return }
            // The way back from this step restores the reel as it stands now.
            miniUndoStacks[batchID]?.refreshPlacement(current)
            let reelBefore = Set(miniReelItems.map(\.key))
            let restored: Bool
            switch (target, current) {
            case (.transcript(let picks, _), .transcript(let expected, _)):
                restored = await restoreMiniTranscript(picks, expected: expected, batchID: batchID)
            case (.qa(let state, _), _): restored = await restoreMiniQA(state, batchID: batchID)
            case (.highlights(let state, _), _): restored = await restoreMiniHighlights(state, batchID: batchID)
            default: restored = false
            }
            await settleMiniSaves()
            // History moves only once the section did; a failed restore
            // leaves the step to try again.
            guard generation == profileGeneration, miniRuns[kind]?.batchID == batchID else { return }
            if let target = redo ? miniUndoStacks[batchID]?.redoTarget : miniUndoStacks[batchID]?.undoTarget {
                // Only what the step brought back takes its old place: the
                // rest of the reel may have been arranged since. Also when
                // the restore stopped part way: the retry finds these items
                // already in the reel and would leave them where they landed.
                let returned = Set(miniReelItems.map(\.key).filter { $0.kind == kind }).subtracting(reelBefore)
                restoreMiniReelOrder(target.reelOrder, restored: returned)
            }
            let settled = miniUndoSnapshot(kind)
            guard restored else {
                if let settled { miniUndoStacks[batchID]?.settleCurrent(settled) }
                return
            }
            if redo {
                miniUndoStacks[batchID]?.stepForward(settledAs: settled)
            } else {
                miniUndoStacks[batchID]?.stepBack(settledAs: settled)
            }
        }
    }

    /// Runs the store's own actions as the restore, not as the user: they
    /// pass the block that holds user edits back while Undo works. Only
    /// synchronous work goes in here, so no user edit can slip in with it.
    private func asMiniRestore(_ actions: () -> Void) {
        isRestoringMiniUndo = true
        defer { isRestoringMiniUndo = false }
        actions()
    }

    /// Whether every save a restore queued reached the database. Each save
    /// has already reported its own failure.
    private func miniRestoreSaved(_ saves: [Task<Void, Error>?]) async -> Bool {
        var saved = true
        for save in saves {
            do { try await save?.value } catch { saved = false }
        }
        return saved
    }

    private func restoreMiniTranscript(_ picks: [TranscriptPick], expected: [TranscriptPick], batchID: String) async -> Bool {
        guard let run = miniRuns[.transcript], run.batchID == batchID, let database else { return false }
        let projectID = run.projectID
        let videoID = run.video.id
        let shownSet = TranscriptPickSet.shown(run.transcript?.setKey)
        let generation = profileGeneration
        // In the same queue as every other pick write, so order is kept.
        let previous = transcriptPickSaveTask
        let write = Task { () throws -> (picks: [TranscriptPick], remapped: [Int64: Int64]) in
            _ = try? await previous?.value
            return try await database.restoreTranscriptPicks(projectID: projectID, videoID: videoID,
                                                             expected: expected, picks: picks, set: shownSet)
        }
        transcriptPickSaveTask = Task { _ = try await write.value }
        do {
            let restored = try await write.value
            guard generation == profileGeneration, miniRuns[.transcript]?.batchID == batchID else { return false }
            miniRuns[.transcript]?.transcript?.picks = restored.picks
            miniUndoStacks[batchID]?.remap(pickIDs: restored.remapped)
            // The other sections of this source name the pick in their reel
            // orders, a Length that is not on screen included.
            let source = MiniReelKey(projectID: projectID, videoID: videoID)
            for (other, owner) in miniUndoStackSources where other != batchID && owner == source {
                miniUndoStacks[other]?.remapReel(pickIDs: restored.remapped)
            }
            return true
        } catch TranscriptPickRestoreError.changed(let stored) {
            // The list changed under the screen (a sync that stopped before
            // it could say so). Show it; the history no longer applies.
            guard generation == profileGeneration, miniRuns[.transcript]?.batchID == batchID else { return false }
            miniRuns[.transcript]?.transcript?.picks = stored
            miniUndoStacks[batchID]?.reset(to: .transcript(picks: stored, reelOrder: miniReelItems.map(\.key)))
            return false
        } catch {
            if generation == profileGeneration { presentError("Could not restore the picks", error) }
            return false
        }
    }

    private func restoreMiniQA(_ state: MiniUndoSnapshot.QA, batchID: String) async -> Bool {
        guard let qa = miniRuns[.qa]?.qa, miniRuns[.qa]?.batchID == batchID else { return false }
        // Only the exchanges that state knew are put back; one grouped or
        // kept since then stays as it is.
        let owned = Set(state.ranges.keys)
        let known = owned.intersection(qa.sections.map(\.id))
        // Each queued save is kept: the queue's last task does not fail
        // for an earlier one.
        var saves: [Task<Void, Error>?] = []
        asMiniRestore {
            let before = qaPickSaveTask
            setMiniQAKept(state.kept.intersection(known).union(qa.kept.subtracting(owned)), batchID: batchID)
            if qaPickSaveTask != before { saves.append(qaPickSaveTask) }
            let kept = qaPickSaveTask
            reorderMiniQAKept(state.order.filter(known.contains), batchID: batchID)
            if qaPickSaveTask != kept { saves.append(qaPickSaveTask) }
            for section in qa.sections {
                guard let range = state.ranges[section.id],
                      abs(range.lowerBound - section.range.lowerBound) > 0.001
                        || abs(range.upperBound - section.range.upperBound) > 0.001 else { continue }
                let trim = sceneEditSaveTask
                setSceneEditRange(section.scene, start: range.lowerBound, end: range.upperBound)
                if sceneEditSaveTask != trim { saves.append(sceneEditSaveTask) }
            }
        }
        if await miniRestoreSaved(saves) { return true }
        // Keeps and order were shown before they were saved; show what is
        // stored, so the step can be tried again. (A trim only reaches the
        // section once saved.)
        if let run = miniRuns[.qa], run.batchID == batchID, let database,
           let kept = try? await database.fetchQAPicks(projectID: run.projectID, videoID: run.video.id),
           miniRuns[.qa]?.batchID == batchID, let now = miniRuns[.qa]?.qa {
            let known = Set(now.sections.map(\.id))
            miniRuns[.qa]?.qa?.kept = Set(kept).intersection(known)
            miniRuns[.qa]?.qa?.keptOrder = kept.filter(known.contains)
        }
        return false
    }

    private func restoreMiniHighlights(_ state: MiniUndoSnapshot.Highlights, batchID: String) async -> Bool {
        guard let run = miniRuns[.highlights], run.batchID == batchID, miniFootageKind == .highlights else { return false }
        let known = Set(run.candidates.map(\.id))
        // Keep and order are remembered outside the database and cannot
        // fail; each plan is saved, and shown before its save.
        struct PlanSave { var candidate: MiniWizardCandidate; var revision: Int; var save: Task<Void, Error>? }
        var planSaves: [PlanSave] = []
        asMiniRestore {
            setMiniHighlightsKept(state.kept.intersection(known), batchID: batchID)
            reorderMiniHighlightCandidates(state.order, batchID: batchID)
            for candidate in miniRuns[.highlights]?.candidates ?? [] {
                // A take chosen since then has its own plan; leave it.
                let revision = miniPlanRevisions[candidate.take.id, default: 0]
                guard let saved = state.plans[candidate.id], saved.takeID == candidate.take.id,
                      saved.revision != revision else { continue }
                let before = wizardSelectionSaveTask
                saveMiniCandidatePlan(saved.plan, selectionID: candidate.id, takeID: candidate.take.id)
                if wizardSelectionSaveTask != before {
                    planSaves.append(.init(candidate: candidate, revision: revision, save: wizardSelectionSaveTask))
                }
            }
        }
        var restored = true
        for entry in planSaves {
            do { try await entry.save?.value } catch {
                restored = false
                // Not stored: the take shows the plan it had, as it had it.
                guard miniRuns[.highlights]?.batchID == batchID,
                      let index = miniRuns[.highlights]?.candidates.firstIndex(where: {
                          $0.id == entry.candidate.id && $0.take.id == entry.candidate.take.id }) else { continue }
                miniRuns[.highlights]?.candidates[index].take = entry.candidate.take
                miniPlanRevisions[entry.candidate.take.id] = entry.revision
            }
        }
        return restored
    }
}
