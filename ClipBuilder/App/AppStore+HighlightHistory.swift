import Foundation

/// Highlight history capture (docs/Highlight-History-Plan.md, Phase 1):
/// every Express candidate, Express render, and full-wizard reel is written
/// to `wizard_highlights` with the settings that made it and its author.
/// A failed history write is logged and never fails the run.
extension AppStore {
    /// The Team Sync signed-in email while the profile is attached, else
    /// this Mac's user name.
    var currentHighlightAuthor: String {
        let email = teamSync.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if teamSync.attached, teamSync.signedIn, !email.isEmpty { return email }
        return NSFullUserName()
    }

    /// Settings for a history row: the run's options plus, for Express, the
    /// picks or kept exchanges as they stand, by video hash and source time.
    func highlightSettings(options: WizardOptions, run: MiniWizardRun? = nil, mini: MiniWizardSettings? = nil,
                           length: MiniWizardFlow.Length? = nil) -> WizardHighlightSettings {
        var result = WizardHighlightSettings(options: options, mini: mini, length: length?.rawValue,
            outputMode: mini?.outputMode.rawValue, aiRouting: HighlightAIRouting(settings.ai),
            sourceProfile: activeProfile.profileName)
        guard let run else { return result }
        let hash = run.video.hash
        switch run.footageKind {
        case .transcript:
            result.picks = run.transcript?.picks.filter(\.kept).map {
                HighlightPickSnapshot(kind: .transcript, videoHash: hash, start: $0.start, end: $0.end,
                                      position: $0.position, eventTimes: nil)
            }
        case .fightMetrics:
            let times = Dictionary((fightEvents[run.video.id] ?? []).map { ($0.id, $0.time) },
                                   uniquingKeysWith: { first, _ in first })
            result.picks = run.fight?.picks.map { pick in
                HighlightPickSnapshot(kind: .fight, videoHash: hash, start: pick.start, end: pick.end,
                                      position: pick.position, eventTimes: pick.eventIDs.compactMap { times[$0] })
            }
        case .qa:
            if let qa = run.qa {
                result.qaKept = qa.sections.filter { qa.kept.contains($0.id) }.map {
                    HighlightFootageRef(sceneID: $0.id, videoHash: hash, start: $0.scene.startTime, end: $0.scene.endTime)
                }
            }
        case .highlights:
            break
        }
        return result
    }

    /// One row per Express candidate take.
    func recordHighlightCandidates(_ candidates: [MiniWizardCandidate], projectID: Int64, flow: WizardHighlightFlow,
                                   batchID: String?, settings: WizardHighlightSettings,
                                   parentID: Int64? = nil, note: String? = nil) async {
        guard let database, !candidates.isEmpty else { return }
        let author = currentHighlightAuthor
        let drafts = candidates.map { candidate in
            WizardHighlightDraft(projectID: projectID, flow: flow, batchID: batchID, parentID: parentID,
                selectionID: candidate.selection.id, takeID: candidate.take.id, settings: settings,
                plan: candidate.take.plan,
                provenance: candidate.take.provenance.map { [AIRole(role: "Plan", provenance: $0)] } ?? [],
                note: note, author: author)
        }
        do {
            for draft in drafts { try await database.insertWizardHighlight(draft) }
        } catch {
            appendLog(\.wizardLog, ["Could not save highlight history: \(error.localizedDescription)"])
        }
        await reloadHighlightHistories(projectID: projectID)
    }

    /// One row per rendered reel.
    func recordHighlights(forGenerated videos: [GeneratedVideoRecord], projectID: Int64,
                          capture: WizardHighlightCapture) async {
        guard let database, !videos.isEmpty else { return }
        do {
            try await database.insertWizardHighlights(forGeneratedVideos: videos, projectID: projectID,
                flow: capture.flow, settings: capture.settings, author: currentHighlightAuthor)
        } catch {
            appendLog(\.wizardLog, ["Could not save highlight history: \(error.localizedDescription)"])
        }
        await reloadHighlightHistories(projectID: projectID)
    }
}

/// What an opened Express entry hands back to the Express page, which owns
/// the Settings step, length and footage tab.
struct ExpressHighlightOpened {
    var mini: MiniWizardSettings?
    var length: MiniWizardFlow.Length
    var outputMode: MiniWizardFlow.OutputMode?
    var batchID: String
}

/// A full-wizard entry opened on this library: the saved plan with its
/// scenes resolved here, and the options it ran with.
struct OpenedWizardHighlight {
    var id: Int64
    var plan: WizardPlan
    var sceneMap: [Int64: SceneRecord]
    var options: WizardOptions
    var rows: [HighlightPlanClipRow]
}

/// Highlight history selector (docs/Highlight-History-Plan.md, Phase 2).
extension AppStore {
    static let highlightNotInLibrary = "Source video not in your library"

    func resetHighlightHistory() {
        highlightHistories = [:]
        selectedHighlightIDs = [:]
        unavailableHighlightIDs = []
        highlightOpenWarnings = [:]
        openedHighlightBatches = [:]
        openedWizardHighlight = nil
        highlightOpenToken += 1
    }

    func highlightHistory(_ scope: HighlightHistoryScope) -> [WizardHighlightRecord] {
        highlightHistories[scope] ?? []
    }

    func selectedHighlight(_ scope: HighlightHistoryScope) -> WizardHighlightRecord? {
        guard let id = selectedHighlightIDs[scope] else { return nil }
        return highlightHistory(scope).first { $0.id == id }
    }

    /// Express's list for one source video.
    func loadHighlightHistory(projectID: Int64, videoHash: String) async {
        await loadHighlightHistory(.express(projectID: projectID, videoHash: videoHash))
    }

    func loadHighlightHistory(_ scope: HighlightHistoryScope) async {
        guard let database else { return }
        let generation = profileGeneration
        do {
            let rows = try await database.fetchHighlights(projectID: scope.projectID, videoHash: scope.videoHash)
            let localHashes = Set(try await database.highlightLocalVideos().map(\.hash))
            guard generation == profileGeneration else { return }
            let entries = rows.filter(scope.includes)
            let ids = Set(entries.map(\.id))
            highlightHistories[scope] = entries
            unavailableHighlightIDs = unavailableHighlightIDs.subtracting(ids)
                .union(HighlightHistoryNavigation.unavailableIDs(entries, localHashes: localHashes))
            if let selected = selectedHighlightIDs[scope], !ids.contains(selected) { selectedHighlightIDs[scope] = nil }
        } catch {
            if generation == profileGeneration {
                appendLog(\.wizardLog, ["Could not load highlight history: \(error.localizedDescription)"])
            }
        }
    }

    /// After a capture: every list of the project shown so far.
    func reloadHighlightHistories(projectID: Int64) async {
        for scope in Array(highlightHistories.keys) where scope.projectID == projectID {
            await loadHighlightHistory(scope)
        }
    }

    /// Marks an entry that cannot be opened here; true when it can.
    private func checkHighlightAvailable(_ id: Int64) -> Bool {
        guard unavailableHighlightIDs.contains(id) else { return true }
        highlightOpenWarnings[id] = Self.highlightNotInLibrary
        return false
    }

    /// Express Open: the entry's plan, resolved to this library's scenes by
    /// video hash and source time, becomes the Highlights run's one candidate
    /// (a new saved selection in a new mini batch, as Generate highlights
    /// writes them). The caller applies the returned Settings, length and
    /// output mode to the page.
    func openExpressHighlight(id: Int64, scope: HighlightHistoryScope, video: VideoRecord) async -> ExpressHighlightOpened? {
        selectedHighlightIDs[scope] = id
        guard checkHighlightAvailable(id), let database, let projectID = activeProjectID,
              projectID == scope.projectID, !isWizardRunning else { return nil }
        guard video.isPresent else { presentError(VideoRecord.notPresentReason); return nil }
        let generation = profileGeneration
        highlightOpenToken += 1
        let token = highlightOpenToken
        let source = miniFootageVideoID
        // A newer Open, or a source switch on the page, while this one awaited.
        func stale() -> Bool { token != highlightOpenToken || miniFootageVideoID != source }
        do {
            guard let record = try await database.fetchHighlight(id: id),
                  let opened = try await database.openHighlight(id: id) else {
                throw WizardSelectionError.missingSelection
            }
            guard generation == profileGeneration, activeProjectID == projectID, !stale() else { return nil }
            guard opened.missingVideoHashes.isEmpty else {
                unavailableHighlightIDs.insert(id)
                highlightOpenWarnings[id] = Self.highlightNotInLibrary
                return nil
            }
            guard let plan = opened.plan, !plan.clips.isEmpty else {
                highlightOpenWarnings[id] = "This highlight has no footage to open."
                return nil
            }
            let settings = record.settings
            let length = settings?.length.flatMap(MiniWizardFlow.Length.init(rawValue:)) ?? .automatic
            var options = settings?.options ?? WizardOptions()
            options.projectID = projectID
            options.sourceVideoPaths = [video.path ?? ""]
            options.sourcesRestricted = true
            options.sourceSceneSelection = false
            options.sourceSceneIDs = []
            options.manualBRoll = true
            options.critiqueLoop = false
            options.workflow = .automatic
            let batch = UUID().uuidString
            let take = try await database.recordWizardTake(projectID: projectID, options: options.step1, plan: plan,
                note: record.note, miniBatch: batch, fallbackName: "From history")
            guard let selection = try await database.wizardSelection(id: take.selectionID) else {
                throw WizardSelectionError.missingSelection
            }
            await refreshWizardSelections()
            // No suspension from here to the return: the page applies the
            // length before it can re-render and drop a run of another length.
            guard generation == profileGeneration, activeProjectID == projectID, !isWizardRunning,
                  !stale() else { return nil }
            cancelMiniFootageLoad()
            miniFootageVideoID = video.id
            miniFootageKind = .highlights
            miniFootageLength = length
            MiniWizardRunCache.retain(&miniRuns, projectID: projectID, videoID: video.id, length: length)
            let candidate = MiniWizardCandidate(selection: selection, take: take)
            miniRuns[.highlights] = MiniWizardRun(projectID: projectID, video: video, footageKind: .highlights,
                length: length, batchID: batch, candidates: [candidate], options: options,
                selectedSelectionID: candidate.id)
            UserDefaults.standard.set(batch, forKey: MiniWizardMemory.batchKey(profileName: activeProfile.profileName,
                projectID: projectID, videoID: video.id, kind: .highlights, length: length))
            openedHighlightBatches[id] = batch
            highlightOpenWarnings[id] = nil
            appendLog(\.wizardLog, ["Express: opened \(HighlightHistoryNavigation.label(for: record))."])
            // Opening may have created scenes for a teammate's ranges.
            let known = Set(scenes.map(\.id)).union(historyScenes.map(\.id))
            if !SceneReferences.ids(in: plan).isSubset(of: known) { refreshAll() }
            let outputMode = (settings?.mini?.outputMode)
                ?? settings?.outputMode.flatMap(MiniWizardFlow.OutputMode.init(rawValue:))
            return ExpressHighlightOpened(mini: settings?.mini, length: length, outputMode: outputMode, batchID: batch)
        } catch {
            if generation == profileGeneration, !stale() { presentError("Could not open the highlight", error) }
            return nil
        }
    }

    /// The Highlights run an opened entry became, while it is still on screen.
    func openedExpressBatch(for id: Int64) -> String? {
        guard let batch = openedHighlightBatches[id], miniRuns[.highlights]?.batchID == batch,
              miniRuns[.highlights]?.projectID == activeProjectID else { return nil }
        return batch
    }

    /// Full wizard Open: the entry's options, with source paths remapped by
    /// video hash to this library, become the options Generate Again runs,
    /// and its saved plan, resolved to this library's scenes (creating the
    /// recorded ranges a teammate's footage needs), becomes
    /// `openedWizardHighlight` for "Show clips" and "Open in Builder".
    @discardableResult
    func openWizardHighlight(id: Int64, scope: HighlightHistoryScope) async -> Bool {
        selectedHighlightIDs[scope] = id
        guard checkHighlightAvailable(id), let database, let projectID = activeProjectID,
              projectID == scope.projectID else { return false }
        let generation = profileGeneration
        highlightOpenToken += 1
        let token = highlightOpenToken
        func current() -> Bool {
            generation == profileGeneration && activeProjectID == projectID && token == highlightOpenToken
                && selectedHighlightIDs[scope] == id
        }
        do {
            guard let record = try await database.fetchHighlight(id: id) else { throw WizardSelectionError.missingSelection }
            let local = try await database.highlightLocalVideos()
            guard current() else { return false }
            let localHashes = Set(local.map(\.hash))
            guard (record.videoHashes ?? []).allSatisfy({ $0.isEmpty || localHashes.contains($0) }) else {
                unavailableHighlightIDs.insert(id)
                highlightOpenWarnings[id] = Self.highlightNotInLibrary
                return false
            }
            guard let settings = record.settings else {
                highlightOpenWarnings[id] = "This highlight's settings could not be read."
                return false
            }
            let options = HighlightHistoryNavigation.localOptions(settings.options,
                videoHashes: record.videoHashes ?? [], localVideos: local, projectID: projectID,
                author: record.author, localAuthor: currentHighlightAuthor)
            // The saved plan on this library. A row without a plan (or one
            // whose footage no longer resolves) still opens its settings.
            var opened: OpenedWizardHighlight?
            if record.plan != nil, let result = try await database.openHighlight(id: id),
               result.missingVideoHashes.isEmpty, let plan = result.plan, !plan.clips.isEmpty {
                let ids = SceneReferences.ids(in: plan)
                let scenes = try await database.fetchScenes(ids: ids)
                let sceneMap = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                opened = OpenedWizardHighlight(id: id, plan: plan, sceneMap: sceneMap, options: options,
                    rows: HighlightHistoryNavigation.clipRows(plan, sceneMap: sceneMap))
            }
            guard current() else { return false }
            lastWizardOptions = options
            openedWizardHighlight = opened
            wizardFailureMessage = nil
            highlightOpenWarnings[id] = record.plan != nil && opened == nil
                ? "This highlight's clips could not be resolved; Generate again still runs its settings." : nil
            appendLog(\.wizardLog, ["Wizard: opened \(HighlightHistoryNavigation.label(for: record))."])
            if let opened {
                // Opening may have created scenes for a teammate's ranges.
                let known = Set(scenes.map(\.id)).union(historyScenes.map(\.id))
                if !Set(opened.sceneMap.keys).isSubset(of: known) { refreshAll() }
            }
            return true
        } catch {
            if current() { presentError("Could not open the highlight", error) }
            return false
        }
    }

    /// The opened entry, while it is still the selected one of `scope`.
    func openedWizardHighlight(for scope: HighlightHistoryScope) -> OpenedWizardHighlight? {
        guard let opened = openedWizardHighlight, selectedHighlightIDs[scope] == opened.id,
              activeProjectID == scope.projectID else { return nil }
        return opened
    }

    /// "Open in Builder": the opened entry's plan as a new timeline.
    func openWizardHighlightInBuilder(_ opened: OpenedWizardHighlight) {
        openReviewedPlanInBuilder(opened.plan, sceneMap: opened.sceneMap, options: opened.options,
                                  named: "From history")
    }

    /// "Generate again with these settings": open the entry, then rerun it.
    @discardableResult
    func generateWizardHighlightAgain(id: Int64, scope: HighlightHistoryScope) async -> Bool {
        guard !isWizardRunning, await openWizardHighlight(id: id, scope: scope), !isWizardRunning else { return false }
        retryWizard()
        return true
    }
}
