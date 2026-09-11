import Foundation

@MainActor
enum BuilderWizardLibrary {
    /// Same resources and project-scoped database reads as the debug script
    /// preview. The caller checks captured identity/revision after suspension.
    static func snapshot(store: AppStore) async throws -> ScriptLibrarySnapshot {
        let started = ContinuousClock.now
        var library = ScriptLibrarySnapshot(projectID: store.activeProjectID)
        library.videos = store.videos
        library.scenes = store.scenes
        library.people = store.people
        library.layouts = ScreenCropStore.all()
        library.tags = store.activeProfile.tagSchema.values.flatMap { $0 }
        for (index, bumper) in store.bumpers.enumerated() { library.bumpers["bumper:\(index)"] = bumper }
        for (index, sound) in AssetStore.allFiles(of: .music).enumerated() { library.sounds["sound:\(index)"] = sound.name }
        for (index, image) in AssetStore.allFiles(of: .images).enumerated() { library.images["image:\(index)"] = image.url.path }
        if let database = store.database {
            library.videos = try await database.fetchVideos(projectID: library.projectID)
            library.scenes = try await database.fetchScenes(projectID: library.projectID)
            for video in library.videos {
                try Task.checkCancellation()
                guard started.duration(to: .now) < .seconds(10) else {
                    throw ScriptError.invalid("Library snapshot exceeded ten seconds. Try again with a smaller project.")
                }
                library.transcripts += try await database.fetchTranscripts(videoID: video.id)
                library.features += try await database.fetchTranscriptFeatures(videoID: video.id)
                library.proposals += try await database.fetchEditProposals(videoID: video.id)
                if !(try await database.fetchVideoPeople(videoID: video.id)).isEmpty { library.videosWithPeople.insert(video.id) }
            }
        }
        try Task.checkCancellation()
        guard started.duration(to: .now) < .seconds(10) else {
            throw ScriptError.invalid("Library snapshot exceeded ten seconds. Try again with a smaller project.")
        }
        return library
    }
}
