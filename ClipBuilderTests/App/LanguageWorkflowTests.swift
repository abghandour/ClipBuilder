import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Project language workflow", .serialized)
struct LanguageWorkflowTests {
    private func fixture(_ temp: TempDatabase) async throws -> (AppStore, VideoRecord) {
        var profile = Fixtures.brand()
        profile.editing = ProfileEditingDefaults()
        profile.editing?.footage.language = "en-US"
        let settings = AppSettings()
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai), database: temp.database)
        store.languageProbe = LanguageProbe(recognizer: { locale in locale == "pt-BR" ? .downloadable : .installed },
                                           translation: { _, _ in .installed }, dubVoice: { _, _ in .installed })
        let id = try await temp.database.createProject(profileName: profile.profileName, name: "Portuguese")
        try await temp.database.setProjectLanguages(id: id, languages: ProjectLanguages(spoken: ["pt-BR"]))
        store.projects = try await temp.database.fetchProjects()
        store.activeProjectID = id
        let videoID = try await temp.seedVideo()
        var video = try #require(try await temp.database.video(id: videoID))
        video.videoType = "podcast"
        store.videos = [video]
        return (store, video)
    }

    @Test func analysisRequestCapturesProjectLanguageForPodcast() async throws {
        let temp = try await TempDatabase()
        let (store, video) = try await fixture(temp)
        let request = try await store.captureAnalysisRequest(video: video, plan: AnalysisCheckpoint.Plan(),
            profile: store.activeProfile, config: store.effectiveAIConfig, podcast: store.podcastEditingSettings,
            language: store.transcriptionLanguage(for: video))
        #expect(request.language == "pt-BR")
        #expect(request.spokenLocales == ["pt-BR"])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object.removeValue(forKey: "spokenLocales")
        let legacy = try JSONDecoder().decode(AnalysisRequest.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.spokenLocales == nil)
    }

    @Test func wizardStopsOnProjectRecognizerEvenWhenProfileIsInstalled() async throws {
        let temp = try await TempDatabase()
        let (store, video) = try await fixture(temp)
        store.startPipeline(videos: [video], options: PipelineOptions())
        await store.pipelineTask?.value
        #expect(!store.isPipelineRunning)
        #expect(store.pipelineStage == "stopped")
        #expect(store.pipelineDone.isEmpty)
        #expect(store.currentError?.details.contains("recognizer") == true)
        #expect(store.transcriptionLanguage(for: video) == "pt-BR")
        #expect(try await temp.database.fetchTranscripts(videoID: video.id).isEmpty)
    }

    @Test func manualTranscriptionStopsBeforeReadingFixtureMedia() async throws {
        let temp = try await TempDatabase()
        let (store, video) = try await fixture(temp)
        store.transcribe(video: video)
        await store.transcriptionTasks[video.id]?.value
        #expect(store.currentError?.details.contains("recognizer") == true)
        #expect(store.transcribingVideoIDs.isEmpty)
        #expect(try await temp.database.fetchTranscripts(videoID: video.id).isEmpty)
    }

    @Test func assistantsOfferInstallWithMissingAssetInsight() async throws {
        let temp = try await TempDatabase()
        let (store, _) = try await fixture(temp)
        await store.refreshLanguageReadiness()
        for assistant: any PageAssistant in [ProjectsAssistant(), SourcesAssistant()] {
            let context = assistant.context(store: store)
            let insight = assistant.suggestions(for: context).first { $0.id == "languages.missing" }
            #expect(insight?.kind == .insight)
            #expect(insight?.actionID == "languages.install")
            #expect(assistant.actions(store: store).contains { $0.id == "languages.install" })
        }
        #expect(ProjectsAssistant.route("Install project languages") == "languages.install")
        #expect(SourcesAssistant.route("Install missing recognizers") == "languages.install")
    }
    @Test func analysisBatchStopsBeforeStartingAnyStep() async throws {
        let temp = try await TempDatabase()
        let (store, video) = try await fixture(temp)
        store.runMissingAnalysisSteps([video.id: [.transcript, .people]], videos: [video], syncWhenDone: false)
        for _ in 0..<100 where store.currentError == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.currentError?.details.contains("recognizer") == true)
        #expect(store.analysisStepBatch == nil)
        #expect(!store.isDetectingPeople)
        #expect(store.transcribingVideoIDs.isEmpty)
    }

    @Test func translationInstallStaysOwnedByJobUntilStopped() async throws {
        let temp = try await TempDatabase()
        let (store, _) = try await fixture(temp)
        store.languageProbe = LanguageProbe(recognizer: { _ in .installed }, translation: { _, _ in .downloadable },
                                           dubVoice: { _, _ in .installed })
        store.installLanguageAssets()
        for _ in 0..<100 where store.languageTranslationInstall == nil { try await Task.sleep(for: .milliseconds(10)) }
        let work = try #require(store.languageTranslationInstall)
        #expect(work.projectID == store.activeProjectID)
        #expect(work.generation == store.profileGeneration)
        #expect(work.pending.map(\.language) == ["pt→en"])
        #expect(store.jobs.running.contains { $0.kind == .languageAssets })
        await store.jobs.cancelAndWait(kind: .languageAssets)
        #expect(store.languageTranslationInstall == nil)
        #expect(!store.jobs.running.contains { $0.kind == .languageAssets })
    }

}
