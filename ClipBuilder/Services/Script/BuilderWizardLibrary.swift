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
        let language = store.settings.transcribeLanguage
        if let database = store.database {
            library = try await library.refreshed(database: database, language: language)
        }
        try Task.checkCancellation()
        guard started.duration(to: .now) < .seconds(10) else {
            throw ScriptError.invalid("Library snapshot exceeded ten seconds. Try again with a smaller project.")
        }
        return library
    }
}
