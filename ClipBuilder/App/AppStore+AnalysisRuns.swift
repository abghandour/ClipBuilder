import Foundation

extension AppStore {
    func activeLayer(videoID: Int64) -> ActiveLayers.Resolution {
        ActiveLayers.resolve(videoID: videoID,
                             pinnedRunKey: videos.first { $0.id == videoID }?.activeRunKey,
                             runs: analysisRuns, passes: analysisPasses)
    }

    var activeRunIDs: Set<Int64> {
        Set(videos.compactMap { activeLayer(videoID: $0.id).run?.id })
    }

    func pinAnalysisRun(videoID: Int64, runKey: String?) {
        guard let database else { return }
        Task {
            do {
                try await database.setActiveRunKey(videoID: videoID, runKey: runKey)
                await refreshAllNow()
            } catch { presentError("Could not change the active batch", error) }
        }
    }

    func mergeAnalysisRuns(_ runs: [AnalysisRun], preferred: AnalysisRun) {
        guard let database else { return }
        Task {
            do {
                try await database.mergeAnalysisRuns(ids: Set(runs.map(\.id)), preferredID: preferred.id)
                await refreshAllNow()
            } catch { presentError("Could not merge the batches", error) }
        }
    }

    /// Load current references before presenting any destructive confirmation.
    func prepareBatchDeletion(_ present: @escaping @MainActor () -> Void) {
        guard let database else { return }
        let generation = profileGeneration
        Task {
            do {
                let references = try await database.fetchSceneReferences()
                guard generation == profileGeneration else { return }
                sceneReferences = references
                present()
            } catch { if generation == profileGeneration { presentError("Could not check batch references", error) } }
        }
    }

    func batchDeletionMessage(_ runs: [AnalysisRun]) -> String {
        let runIDs = Set(runs.map(\.id))
        let ids = Set(historyScenes.filter { $0.runID.map(runIDs.contains) == true }.map(\.id))
        var references = sceneReferences.filter { !$0.sceneIDs.isDisjoint(with: ids) }.map(\.label)
        if builder.document.videoTrack.contains(where: { $0.sceneID.map(ids.contains) == true }),
           !sceneReferences.contains(where: { $0.kind == .builder && $0.id == openTimelineID && !$0.sceneIDs.isDisjoint(with: ids) }) {
            references.append("Builder document: open timeline")
        }
        let detail = references.isEmpty ? "No saved references." : "References to these scenes:\n" + references.joined(separator: "\n")
        return "Deletes these batches, scenes, tags and ratings. Any pin to a deleted batch is cleared. Source videos stay. Referenced scenes will no longer be available.\n\n" + detail
    }

    /// The returned task finishes once the document's referenced scenes are in
    /// the Builder cache; `openTimelineRecord` keeps it in `sceneHydration`.
    @discardableResult
    func hydrateReferencedScenes(ids: Set<Int64>) -> Task<Void, Never>? {
        guard let database else { return nil }
        let generation = profileGeneration
        return Task { [self] in
            do {
                let fresh = try await database.fetchScenes(ids: ids)
                guard generation == profileGeneration else { return }
                referencedScenes = SceneReferences.combining(fresh, referenced: referencedScenes)
                builderLibraryHydration.refresh { [weak self] in
                    guard let self, generation == self.profileGeneration else { return }
                    self.builder.updateScenes(self.scenes, referencedScenes: self.referencedScenes)
                }
            } catch { if generation == profileGeneration { presentError("Could not load referenced scenes", error) } }
        }
    }
}
