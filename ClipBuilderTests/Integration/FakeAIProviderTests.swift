import Foundation
import Testing
@testable import Clip_Builder

/// The fake provider is a shell script that answers with canned JSON keyed
/// by a marker in the prompt (see Fixtures/fake-claude.sh). These tests run
/// the real prompt builders, response parsing, and persistence around it.
@Suite("Fake AI provider integration", .tags(.integration), .serialized,
       .enabled(if: FixtureVideo.integrationsAvailable,
                "Install ffmpeg and ffprobe to run."))
struct FakeAIProviderTests {
    /// An AIService whose every task routes to the fake script.
    private func makeService() throws -> AIService {
        let script = try #require(Bundle(for: FakeAIBundleToken.self)
            .url(forResource: "fake-claude", withExtension: "sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        ProcessRunner.resetLocateCache()
        var config = AIConfig()
        for task in ["captions", "analysis", "wizard", "parse"] {
            config.tasks[task] = "claude"
        }
        config.providers["claude"] = AIProviderSettings(bin: script.path, model: "fixture")
        return AIService(config: config)
    }

    @Test("configured provider subprocess returns parseable canned JSON")
    func providerCall() async throws {
        let service = try makeService()
        let response = try await service.call(
            prompt: "Write a caption", task: "captions", provider: "claude", timeout: 5
        )
        #expect(response.provider == "claude")
        #expect(AIResponseParser.jsonObject(from: response.text)?["caption"] as? String == "Fixture caption")
    }

    @Test("visual analysis persists scenes and moments from the provider's reply")
    func analysisPersists() async throws {
        let scope = try DataFolderOverride()
        _ = scope
        let temp = try TempDatabase()
        let source = try await FixtureVideo.make(in: temp.directory.url, wide: true)
        let videoID = try await temp.database.registerVideo(
            hash: "analysis-fixture", filename: source.lastPathComponent, path: source.path,
            duration: 3, width: 1920, height: 1080, wide: true
        )
        let video = try #require(try await temp.database.fetchVideos().first { $0.id == videoID })

        let analyzer = Analyzer(ai: try makeService())
        let result = try await analyzer.analyzeVisual(
            video: video, profile: Fixtures.brand(name: "Analysis"), database: temp.database,
            runName: "Fixture run", detectPeople: false,
            log: { _ in }, progress: { _, _ in }
        )
        #expect(result.runID != nil)

        let scenes = try await temp.database.fetchScenes(videoID: videoID)
        #expect(scenes.count == 1)
        #expect(scenes.first?.tags == ["striking"])
        #expect(scenes.first?.startTime == 0)
        #expect(scenes.first?.endTime == 3)
        let analyzed = try #require(try await temp.database.fetchVideos().first { $0.id == videoID })
        #expect(analyzed.visualAnalyzerProvider == "claude")
    }

    @Test("wizard planning turns the provider's reply into a validated plan over real scenes")
    func planFromScenes() async throws {
        let scope = try DataFolderOverride()
        _ = scope
        let temp = try TempDatabase()
        let source = try await FixtureVideo.make(in: temp.directory.url, wide: true)
        let videoID = try await temp.database.registerVideo(
            hash: "plan-fixture", filename: source.lastPathComponent, path: source.path,
            duration: 3, width: 1920, height: 1080, wide: true
        )
        _ = try await temp.database.saveAnalysis(
            videoID: videoID, runName: "Fixture", instructions: "", sampleInterval: 1,
            notesJSON: nil, tagRanges: ["striking": [(start: 0, end: 3)]], moments: [],
            analyzedTags: ["striking"], provider: "claude", model: "fixture", mode: "visual"
        )
        let scene = try #require(try await temp.database.fetchScenes(videoID: videoID).first)

        let wizard = WizardEngine(ai: try makeService(), render: RenderEngine())
        var options = WizardOptions()
        options.useMusic = false
        options.useFightResearch = false
        let log = LogSink()
        let (plan, sceneMap) = try await wizard.plan(
            options: options, profile: Fixtures.brand(name: "Plan"), database: temp.database,
            emit: { log.append($0) }
        )
        #expect(plan.clips.count == 1)
        #expect(plan.clips.first?.sceneID == scene.id)
        #expect(plan.clips.first?.start == 0)
        #expect(plan.clips.first?.end == 3)
        #expect(plan.provenance?.provider == "claude")
        #expect(sceneMap[scene.id] != nil)
        #expect(log.lines.contains { $0.hasPrefix("Plan: 1 clips") })
    }
}

private final class FakeAIBundleToken {}

/// Collects `emit` lines from a @Sendable callback.
private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.withLock { storage } }
    func append(_ line: String) { lock.withLock { storage.append(line) } }
}
