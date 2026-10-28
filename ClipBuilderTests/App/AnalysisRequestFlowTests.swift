import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Analysis request orchestration", .serialized)
struct AnalysisRequestFlowTests {
    private func store(_ temp: TempDatabase) -> AppStore {
        let profile = Fixtures.brand(name: "Analysis request fixture")
        let settings = AppSettings()
        return AppStore(settings: settings, profiles: [profile], active: profile,
                        ai: AIService(config: settings.ai), database: temp.database)
    }

    @Test func reanalyzeBatchRestoresFullPortableRequest() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let video = try #require(try await temp.database.video(id: videoID))
        let store = store(temp)
        store.videos = [video]
        let keys = ["instructions", "sampleInterval", "includeTranscript", "detectPeople", "autoZoomUnframed", "autoBreakdown", "breakdownTags", "trimStart", "trimEnd", "requiredPeople", "pastedNotes", "smartSampling"]
        let original = keys.map { ($0, UserDefaults.standard.object(forKey: "analysis.\($0)")) }
        defer { for (key, value) in original { UserDefaults.standard.set(value, forKey: "analysis.\(key)") } }
        var request = AnalysisRequestTests.request()
        request.plan = AnalysisCheckpoint.Plan(instructions: "Only the marked round", sampleInterval: 0.5,
            detectPeople: false, autoZoomUnframed: true, breakdownTags: ["kick"], trimRange: [1, 7], requiredPeopleKeys: ["fighter"],
            smartSampling: false, includeTranscript: true, includeFightScoring: false)
        request.sourceIdentity = try ContentHash.fingerprint(of: video.url)
        request.notes = [.init(at: 2, note: "Start here")]
        request.tags = ["action": ["kick"]]
        request.domain = "Saved domain"
        request.tasteRubric = "Saved taste"
        request.markers = [.init(at: 2, x: 0.1, y: 0.2, width: 0.3, height: 0.4, personKey: "fighter", ignored: false)]
        request.people = [.init(key: "fighter", descriptor: "Saved gloves")]
        request.onDevice = ["podcast-exchanges": false, "long-recording": true]
        request.routing = ["analysis": [.init(provider: "claude", model: "saved-model")], "people": [.init(provider: "gemini", model: "saved-people")]]
        request.language = "pt"
        var podcast = PodcastSettings()
        podcast.highlightThreshold = 9; podcast.speakerHoldSeconds = 3
        request.podcastJSON = AnalysisRequest.json(podcast)
        request.transcriptKey = "saved-transcript"
        request.transcriptHash = "saved-transcript-hash"
        var run = try #require(try await temp.database.fetchAnalysisRuns().first)
        run.requestJSON = request.json
        run.requestHash = request.fingerprint
        store.reanalyzeBatch(run)
        #expect(store.restoredAnalysisRequests[videoID] == request.normalized)
        #expect(store.pendingAnalyzeSetup?.id == videoID)
        let plan = AnalysisRequest.capturePlan(defaults: .standard, singleVideo: true, provider: nil, model: nil,
                                               includeFightScoring: request.plan.includeFightScoring)
        #expect(plan.trimRange == [1, 7] && plan.requiredPeopleKeys == ["fighter"])
        #expect(plan.pastedNotes == request.notes)
        let restored = try await store.captureAnalysisRequest(video: video, plan: plan, profile: store.activeProfile,
            config: store.settings.ai, podcast: PodcastSettings(), language: "en")
        // All input groups survive, not merely the legacy five controls.
        #expect(restored.markers == request.markers && restored.tags == request.tags)
        #expect(restored.routing == request.routing && restored.onDevice == request.onDevice)
        #expect(restored.transcriptKey == request.transcriptKey && restored.transcriptHash == request.transcriptHash)
        #expect(restored.podcastJSON == request.podcastJSON && restored.language == "pt")
        #expect(restored.tasteRubric == request.tasteRubric && restored.domain == request.domain)
        #expect(restored.people == request.people && restored.plan.includeFightScoring == false)
    }

    @Test func analyzeCapturesOneShotsBeforeResumingCheckpointAndBypassesDuplicateSheet() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let video = try #require(try await temp.database.video(id: videoID))
        let store = store(temp)
        store.videos = [video]
        let keys = ["instructions", "sampleInterval", "includeTranscript", "detectPeople", "autoZoomUnframed", "autoBreakdown", "breakdownTags", "trimStart", "trimEnd", "requiredPeople", "pastedNotes", "smartSampling"]
        let original = keys.map { ($0, UserDefaults.standard.object(forKey: "analysis.\($0)")) }
        defer { for (key, value) in original { UserDefaults.standard.set(value, forKey: "analysis.\(key)") } }
        UserDefaults.standard.set(1.0, forKey: "analysis.trimStart")
        UserDefaults.standard.set(7.0, forKey: "analysis.trimEnd")
        UserDefaults.standard.set("required", forKey: "analysis.requiredPeople")
        UserDefaults.standard.set("[{\"at\":2,\"note\":\"Captured before resume\"}]", forKey: "analysis.pastedNotes")
        var stoppedRequest = AnalysisRequestTests.request()
        stoppedRequest.sourceIdentity = try ContentHash.fingerprint(of: video.url)
        stoppedRequest.plan = AnalysisCheckpoint.Plan(instructions: "Original checkpoint plan", detectPeople: false,
            smartSampling: false, includeTranscript: false, includeFightScoring: false)
        stoppedRequest.tags = store.activeProfile.effectiveTags
        stoppedRequest.domain = store.activeProfile.effectiveDomain
        let runID = try await temp.database.saveAnalysis(videoID: videoID, runName: "Stopped", instructions: "", sampleInterval: nil,
            notesJSON: nil, tagRanges: [:], moments: [], analyzedTags: [], provider: nil, model: nil, mode: "visual", request: stoppedRequest)
        let checkpoint = AnalysisCheckpoint(videoID: videoID, startedAt: .now, updatedAt: .now, runName: "Stopped",
            plan: stoppedRequest.plan, request: stoppedRequest, runID: runID, transcriptDone: true, fightScoringDone: true)
        try await temp.database.saveAnalysisCheckpoint(checkpoint)
        store.analyze(videos: [video], includeFightScoring: false)
        await store.analysisTask?.value
        let captured = try #require(store.analysisRequestPreviews[videoID])
        #expect(captured.plan.trimRange == [1, 7])
        #expect(captured.plan.requiredPeopleKeys == ["required"])
        #expect(captured.notes == [.init(at: 2, note: "Captured before resume")])
        #expect(store.analysisLog.contains { $0.contains("resuming the analysis") })
        #expect(store.pendingAnalysisDuplicate == nil)
        #expect(try await temp.database.fetchAnalysisCheckpoint(videoID: videoID) == nil)
        #expect(try await temp.database.fetchAnalysisRuns().first { $0.id == runID }?.requestHash == stoppedRequest.fingerprint)
        #expect(UserDefaults.standard.object(forKey: "analysis.trimStart") == nil)
        // This time the fresh request is exactly equal to a successful batch.
        // A duplicate-before-resume regression would present the sheet here.
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("UPDATE analysis_runs SET request_hash = ?, request_json = ? WHERE id = ?",
                        [.text(captured.fingerprint), .text(captured.json), .integer(runID)])
        var equalCheckpoint = checkpoint
        equalCheckpoint.plan = captured.plan
        equalCheckpoint.request = captured
        try await temp.database.saveAnalysisCheckpoint(equalCheckpoint)
        store.analysisCheckpoints[videoID] = equalCheckpoint
        store.analyze(videos: [video], capturedRequests: [videoID: captured])
        await store.analysisTask?.value
        #expect(store.pendingAnalysisDuplicate == nil)
        #expect(store.analysisLog.contains { $0.contains("resuming the analysis") })
        #expect(try await temp.database.fetchAnalysisCheckpoint(videoID: videoID) == nil)
    }

    @Test func batchSkipsEachSuccessfulMatchWithoutShowingASheet() async throws {
        let temp = try await TempDatabase()
        let firstID = try await temp.seedVideo()
        let url = temp.directory.url.appendingPathComponent("second.mp4")
        try Data("second source".utf8).write(to: url)
        let secondID = try await temp.database.registerVideo(hash: UUID().uuidString, filename: "second.mp4", path: url.path,
            duration: 10, width: 1920, height: 1080, wide: true)
        let first = try #require(try await temp.database.video(id: firstID))
        let second = try #require(try await temp.database.video(id: secondID))
        var requests: [Int64: AnalysisRequest] = [:]
        for video in [first, second] {
            var request = AnalysisRequestTests.request()
            request.sourceIdentity = try ContentHash.fingerprint(of: video.url)
            requests[video.id] = request
            _ = try await temp.database.saveAnalysis(videoID: video.id, runName: "Already complete", instructions: "", sampleInterval: nil,
                notesJSON: nil, tagRanges: [:], moments: [], analyzedTags: [], provider: nil, model: nil, mode: "visual", request: request)
        }
        let store = store(temp)
        store.videos = [first, second]
        let keys = ["trimStart", "trimEnd", "requiredPeople", "pastedNotes"]
        let original = keys.map { ($0, UserDefaults.standard.object(forKey: "analysis.\($0)")) }
        defer { for (key, value) in original { UserDefaults.standard.set(value, forKey: "analysis.\(key)") } }
        store.analyze(videos: [first, second], capturedRequests: requests)
        await store.analysisTask?.value
        #expect(store.pendingAnalysisDuplicate == nil)
        #expect(store.analysisCompletion?.summary == "0 analyzed, 2 skipped as up to date")
        #expect(try await temp.database.fetchAnalysisRuns().count == 3)
    }

    @Test func legacyReanalysisKeepsPartialRestoreFallback() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let store = store(temp)
        store.videos = [try #require(try await temp.database.video(id: id))]
        var run = try #require(try await temp.database.fetchAnalysisRuns().first)
        run.instructions = "Legacy instructions"; run.sampleInterval = 2; run.hasTranscript = true
        // Avoid saving settings to a user profile from this fixture.
        run.provider = nil
        let keys = ["instructions", "sampleInterval", "includeTranscript"]
        let original = keys.map { ($0, UserDefaults.standard.object(forKey: "analysis.\($0)")) }
        defer { for (key, value) in original { UserDefaults.standard.set(value, forKey: "analysis.\(key)") } }
        store.reanalyzeBatch(run)
        #expect(store.restoredAnalysisRequests[id] == nil)
        #expect(UserDefaults.standard.string(forKey: "analysis.instructions") == "Legacy instructions")
        #expect(UserDefaults.standard.double(forKey: "analysis.sampleInterval") == 2)
        #expect(UserDefaults.standard.bool(forKey: "analysis.includeTranscript"))
    }

}
