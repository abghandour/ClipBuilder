import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppStore {
    // MARK: - Scene actions

    /// Apply a single-scene change in place after its DB write — refetching
    /// the whole library for a one-row mutation made every rating click
    /// O(library size).
    func updateScene(_ id: Int64, rebuildSceneIndex: Bool = true,
                             rehydrateBuilder: Bool = true,
                             _ mutate: (inout SceneRecord) -> Void) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        rebuildSceneIndexAfterWrite = rebuildSceneIndex
        mutate(&scenes[index])
        // The index keeps record copies for the Favorites filter; when the
        // rebuild is skipped those copies still have to follow the change.
        if !rebuildSceneIndex { sceneIndex.replaceCopy(of: scenes[index]) }
        builder.updateScene(scenes[index], rehydrateClips: rehydrateBuilder)
    }

    /// Apply a bulk mutation to one array copy, so the `scenes` observer
    /// rebuilds its index once instead of once per selected card.
    func updateScenes(_ sceneIDs: Set<Int64>, rebuildSceneIndex: Bool = true,
                              _ mutate: (inout SceneRecord) -> Void) {
        guard !sceneIDs.isEmpty else { return }
        var updatedScenes = scenes
        var affectedScenes: [SceneRecord] = []
        for index in updatedScenes.indices where sceneIDs.contains(updatedScenes[index].id) {
            mutate(&updatedScenes[index])
            affectedScenes.append(updatedScenes[index])
        }
        guard !affectedScenes.isEmpty else { return }
        rebuildSceneIndexAfterWrite = rebuildSceneIndex
        scenes = updatedScenes
        if !rebuildSceneIndex {
            for scene in affectedScenes { sceneIndex.replaceCopy(of: scene) }
        }
        builder.updateChangedScenes(affectedScenes, rehydrateClips: false)
    }

    func toggleFavorite(_ scene: SceneRecord) {
        favoriteScene(scene, favorite: !scene.favorite)
    }

    func chooseStackBest(_ scene: SceneRecord, among members: [SceneRecord]) {
        guard let database else { return }
        Task {
            do {
                for member in members where member.stackChoice && member.id != scene.id {
                    try await database.setSceneStackChoice(member.id, chosen: false)
                    updateScene(member.id, rebuildSceneIndex: false, rehydrateBuilder: false) {
                        $0.stackChoice = false
                    }
                }
                try await database.setSceneStackChoice(scene.id, chosen: true)
                updateScene(scene.id, rebuildSceneIndex: false, rehydrateBuilder: false) {
                    $0.stackChoice = true
                }
            } catch {
                presentError("Could not save the pick", error)
            }
        }
    }

    func setExcluded(_ scene: SceneRecord, excluded: Bool) {
        guard let database else { return }
        Task {
            do {
                try await database.setSceneExcluded(scene.id, excluded: excluded)
                updateScene(scene.id, rehydrateBuilder: false) { $0.excluded = excluded }
            } catch {
                presentError("Could not update the scene", error)
            }
        }
    }

    func setScenesExcluded(_ selectedScenes: [SceneRecord], excluded: Bool) {
        guard let database, !selectedScenes.isEmpty else { return }
        let sceneIDs = Set(selectedScenes.map(\.id))
        Task {
            do {
                try await database.setScenesExcluded(Array(sceneIDs), excluded: excluded)
                updateScenes(sceneIDs) { $0.excluded = excluded }
            } catch {
                presentError("Could not update the scene", error)
            }
        }
    }

    func setSceneBRoll(_ scene: SceneRecord, isBRoll: Bool) {
        guard let database else { return }
        Task {
            do {
                if isBRoll {
                    try await database.addSceneTag(sceneID: scene.id, tag: "b-roll")
                } else {
                    try await database.removeSceneTags(sceneID: scene.id, withPrefix: "b-roll")
                }
                updateScene(scene.id) { changed in
                    changed.tags.removeAll { $0 == "b-roll" }
                    if isBRoll { changed.tags.append("b-roll") }
                }
            } catch {
                presentError("Could not update B-roll status", error)
            }
        }
    }

    func grade(_ scene: SceneRecord, score: Int) {
        guard let database else { return }
        Task {
            do {
                try await database.addGrade(sceneID: scene.id, score: score)
                updateScene(scene.id, rebuildSceneIndex: false, rehydrateBuilder: false) {
                    let total = ($0.gradeAverage ?? 0) * Double($0.gradeCount) + Double(score)
                    $0.gradeCount += 1
                    $0.gradeAverage = total / Double($0.gradeCount)
                    $0.lastGrade = score
                }
            } catch {
                presentError("Could not save the rating", error)
            }
        }
    }

    func gradeScenes(_ selectedScenes: [SceneRecord], score: Int) {
        guard let database, !selectedScenes.isEmpty else { return }
        let sceneIDs = Set(selectedScenes.map(\.id))
        Task {
            do {
                try await database.addGrades(sceneIDs: Array(sceneIDs), score: score)
                updateScenes(sceneIDs, rebuildSceneIndex: false) {
                    let total = ($0.gradeAverage ?? 0) * Double($0.gradeCount) + Double(score)
                    $0.gradeCount += 1
                    $0.gradeAverage = total / Double($0.gradeCount)
                    $0.lastGrade = score
                }
            } catch {
                presentError("Could not save the rating", error)
            }
        }
    }

    // MARK: - Scene editing and favorites

    func favoriteScene(_ scene: SceneRecord, favorite: Bool, provenance: AIProvenance? = nil) {
        guard let database else { return }
        Task {
            do {
                try await database.setSceneFavorite(scene.id, favorite: favorite, provenance: provenance)
                // The write also resets favorite_provider/model: re-read the row.
                await replaceScene(id: scene.id)
            } catch {
                presentError("Could not save the favorite", error)
            }
        }
    }

    func setScenesFavorite(_ selectedScenes: [SceneRecord], favorite: Bool, provenance: AIProvenance? = nil) {
        guard let database, !selectedScenes.isEmpty else { return }
        let sceneIDs = Set(selectedScenes.map(\.id))
        Task {
            do {
                try await database.setScenesFavorite(Array(sceneIDs), favorite: favorite, provenance: provenance)
                updateScenes(sceneIDs) {
                    $0.favorite = favorite
                    $0.favoriteProvider = favorite ? provenance?.provider : nil
                    $0.favoriteModel = favorite ? provenance?.model : nil
                }
            } catch {
                presentError("Could not save the favorite", error)
            }
        }
    }

    /// Apply a curation trim/extend. Passing the original range clears the
    /// override. A stored camera path is recomputed for the new range so the
    /// preview stays truthful.
    func setSceneEditRange(_ scene: SceneRecord, start: Double, end: Double) {
        guard let database, end > start else { return }
        let clearing = abs(start - scene.originalStart) < 0.05
            && abs(end - scene.originalEnd) < 0.05
        let previous = sceneEditSaveTask
        let generation = profileGeneration
        let projectID = activeProjectID
        sceneEditSaveTask = Task {
            _ = try? await previous?.value
            do {
                try await database.setSceneEditRange(scene.id,
                                                     start: clearing ? nil : start,
                                                     end: clearing ? nil : end)
            } catch {
                if generation == profileGeneration { presentError("Could not save the trim", error) }
                throw error
            }
            guard generation == profileGeneration, projectID == activeProjectID else { return }
            updateScene(scene.id) {
                $0.startTime = clearing ? scene.originalStart : start
                $0.endTime = clearing ? scene.originalEnd : end
            }
            refreshMiniQASections()
            if scene.centerStagePathJSON != nil, let stored = scene.centerStagePath {
                // Ends by re-reading this one row, so the new path lands
                // without a whole-library reload.
                startCameraPath(sceneID: scene.id, videoID: scene.videoID,
                                        start: clearing ? scene.originalStart : start,
                                        end: clearing ? scene.originalEnd : end,
                                        camera: stored.camera, reportsFailure: false)
            }
        }
    }

    /// Compute (or refresh) one scene's Center Stage path over a range,
    /// honoring markers, ignores, and hints.
    func computeCameraPath(sceneID: Int64, videoID: Int64,
                           start: Double, end: Double, camera: String) async throws {
        guard let database, end > start,
              let video = videos.first(where: { $0.id == videoID }) else { throw AIError.notConfigured("The source video is unavailable.") }
        let generation = profileGeneration
        let aspect = activeProfile.defaultRenderSettings.aspectRatio
        let centerStage = CenterStageService()
        let markers = (try? await database.personMarkers(videoID: videoID)) ?? []
        let named = markers.filter { $0.personID != nil && !$0.ignored }
        let ignored = markers.filter(\.ignored)
        let portraits = named.isEmpty ? []
            : await Analyzer.markerPortraits(url: video.url, markers: named,
                                             duration: video.duration)
        let avoidPortraits = ignored.isEmpty ? []
            : await Analyzer.markerPortraits(url: video.url, markers: ignored,
                                             duration: video.duration)
        let hints = ((try? await database.centerStageHints(videoID: videoID)) ?? [])
            .filter { $0.atTime >= start - 0.25 && $0.atTime <= end + 0.25 }
            .map { hint in
                (time: min(max(0, hint.atTime - start), end - start),
                 crop: CGRect(x: hint.x, y: hint.y, width: hint.width, height: hint.height))
            }
        let trackingStarted = ContinuousClock.now
        let result = try await centerStage.cameraPath(
                source: video.url, start: start, duration: end - start,
                focusPortraits: portraits, avoidPortraits: avoidPortraits,
                hints: hints, tuning: .named(camera),
                aspect: aspect)
        try Task.checkCancellation()
        guard generation == profileGeneration else { throw CancellationError() }
        guard result.keyframes.count >= 2 else { throw AIError.unusableResponse("No usable camera path was found.") }
        let path = SceneCameraPath(camera: camera, keyframes: result.keyframes)
        if let data = try? JSONEncoder().encode(path),
           let json = String(data: data, encoding: .utf8) {
            try await database.setSceneCenterStagePath(
                sceneID, json: json, seconds: (ContinuousClock.now - trackingStarted).seconds)
        }
        guard generation == profileGeneration else { throw CancellationError() }
        await replaceScene(id: sceneID)
    }
}
