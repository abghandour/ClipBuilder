import Foundation

/// The Instagram post text, written after a video exists and rewritten on
/// request, as a background job so no sheet blocks on the model.
extension AppStore {
    /// True while this video's post text is being written.
    func isWritingPostText(for video: GeneratedVideoRecord) -> Bool {
        jobs.running.contains { $0.kind == .postText && $0.subjectID == String(video.id) }
    }

    /// The live record for a video a sheet captured earlier.
    func currentGeneratedVideo(_ video: GeneratedVideoRecord) -> GeneratedVideoRecord {
        generatedVideos.first { $0.id == video.id } ?? video
    }

    /// Write (or, with existing text or a note, rewrite) the post text for one video.
    func writePostText(for video: GeneratedVideoRecord, note: String? = nil) {
        guard let database else { return }
        let generation = profileGeneration
        let profile = activeProfile
        let wizard = wizard
        var options = WizardOptions()
        options.projectID = video.projectID ?? activeProjectID
        options.accountBenchmarks = igBenchmarks
        options.localHashtags = OnDevicePolicy.isEnabled(item: "hashtags", config: settings.ai)
        let title = (video.caption.isEmpty ? "Post Text — " : "Rewrite Post Text — ") + video.filename
        jobs.start(.postText, title: title, project: activeProject, profileGeneration: generation,
                   subjectID: String(video.id)) { [weak self] log in
            _ = try await wizard.writePostText(video: video, note: note, options: options, profile: profile,
                                               database: database, emit: log)
            guard let self, self.profileGeneration == generation else { return nil }
            await self.refreshAllNow()
            return nil
        }
    }
}
