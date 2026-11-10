import Foundation

/// A Transcribe waiting for the user to pick a word timing.
nonisolated struct TranscriptionChoiceRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    var videoIDs: [Int64]
    var force: Bool
    /// The default from Settings first.
    var options: [WordTiming]
    /// Where it was asked: an answer after a profile or project switch is dropped.
    var profileGeneration: Int
    var projectID: Int64?
    /// The speaker-names step asked for with the transcript; it runs once
    /// the transcription has started, never on the transcript being replaced.
    var thenNameSpeakers = false
    /// The window showing the question, so two windows do not both ask.
    var presenter: UUID?
}

extension AppStore {
    /// Downloads and installs the precise word timing model as a background
    /// job; Settings shows the row, the status bar the progress. `automatic`
    /// is the download a Portuguese project starts by itself: it fails into
    /// the log, not an alert the user did not ask for.
    func installWordTimingModel(automatic: Bool = false) {
        if !automatic { WordAlignerModel.autoInstallDeclined = false }
        wordTimingInstallAutomatic = automatic
        jobs.start(.wordTimingModel, title: "Word Timing Model", project: nil,
                   profileGeneration: profileGeneration, subjectID: "word-timing-model",
                   reportsFailure: !automatic) { log in
            // A 300 MB download, a checksum and a model compile: none of it
            // belongs on the main actor.
            let work = Task.detached(priority: automatic ? .utility : .userInitiated) {
                try await WordAlignerModel.install(log: log)
            }
            do {
                try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            } catch {
                if automatic, !(error is CancellationError) {
                    self.logEvent("job", "Word timing model was not downloaded: \(error.userMessage). Download it in Settings → General → Transcription.")
                }
                throw error
            }
            return nil
        }
    }

    /// A project that speaks Portuguese gets the model without being asked,
    /// once per profile session, unless the user removed it.
    func autoInstallWordTimingModelIfNeeded() {
        guard !BugReporting.isTestHost else { return }
        guard WordTimingRules.shouldAutoInstall(
            spoken: projectLanguages.spoken, installed: WordAlignerModel.isInstalled,
            declined: WordAlignerModel.autoInstallDeclined,
            running: jobs.hasLiveTask(kind: .wordTimingModel),
            attempted: wordTimingAutoInstallGeneration == profileGeneration) else { return }
        wordTimingAutoInstallGeneration = profileGeneration
        logEvent("job", "This project speaks Portuguese: downloading the precise word timing model (260 MB).")
        installWordTimingModel(automatic: true)
    }

    /// Whether a Transcribe of `video` would recognize speech now, rather
    /// than keep the transcript the video already has.
    private func wouldTranscribe(_ video: VideoRecord, force: Bool) -> Bool {
        video.isPresent && !transcribingVideoIDs.contains(video.id)
            && (force || transcriptFacts[video.id] == nil || !transcriptUsable(video))
    }

    /// The word timings a transcription of `videos` can use, the default
    /// from Settings first. One entry: nothing to choose.
    func transcriptionTimingOptions(for videos: [VideoRecord], force: Bool) -> [WordTiming] {
        let languages = videos.filter { wouldTranscribe($0, force: force) }.flatMap { video -> [String] in
            // A language the user chose is the one the recognizer is held to.
            if video.languageSource == VideoLanguage.Source.user.rawValue, let own = video.language, !own.isEmpty {
                return [own]
            }
            return transcriptionLanguages(for: video).spoken
        }
        return WordTimingRules.options(languages: languages, modelInstalled: WordAlignerModel.isInstalled,
                                       preferred: settings.wordTimingChoice)
    }

    /// Transcribe from a control in the main window: asks which word timing
    /// to use when there is a choice, otherwise starts at once.
    /// Returns false when it asked instead of starting; `thenNameSpeakers`
    /// is then run by the answer, after the transcription has started.
    @discardableResult
    func requestTranscription(videos: [VideoRecord], force: Bool = false, thenNameSpeakers: Bool = false) -> Bool {
        let options = transcriptionTimingOptions(for: videos, force: force)
        guard options.count > 1 else {
            for video in videos { transcribe(video: video, force: force) }
            return true
        }
        transcriptionChoiceRequest = TranscriptionChoiceRequest(
            videoIDs: videos.map(\.id), force: force, options: options, profileGeneration: profileGeneration,
            projectID: activeProjectID, thenNameSpeakers: thenNameSpeakers)
        return false
    }

    /// The question was closed without an answer: nothing was started, and
    /// the log says so, since a speaker-names step asked for with it is
    /// dropped too.
    func dismissTranscriptionChoice() {
        guard let request = transcriptionChoiceRequest else { return }
        transcriptionChoiceRequest = nil
        appendLog(\.analysisLog, [request.thenNameSpeakers
            ? "Transcription cancelled; speaker names were not run either."
            : "Transcription cancelled."])
    }

    func resolveTranscriptionChoice(_ request: TranscriptionChoiceRequest, wordTiming: WordTiming) {
        // Answered: the dialog closing after this is not a cancel.
        if transcriptionChoiceRequest?.id == request.id { transcriptionChoiceRequest = nil }
        guard request.profileGeneration == profileGeneration, request.projectID == activeProjectID else { return }
        let ids = Set(request.videoIDs)
        for video in videos where ids.contains(video.id) {
            transcribe(video: video, force: request.force, wordTiming: wordTiming)
            // Waits for the transcription just started, as when both steps run unasked.
            if request.thenNameSpeakers { nameSpeakers(video: video) }
        }
    }
}
