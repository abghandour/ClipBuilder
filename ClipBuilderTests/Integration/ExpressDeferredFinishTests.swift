import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

/// Express hands each reel's social caption back as deferred work so it can
/// overlap the next render. This renders one short real reel and checks that
/// the caption request waits for that work, and that stage timings arrive.
@Suite("Express deferred finish", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable, "Install ffmpeg and ffprobe to run."))
struct ExpressDeferredFinishTests {
    private final class Lines: Sendable {
        private let storage = Mutex<[String]>([])
        func append(_ line: String) { storage.withLock { $0.append(line) } }
        var all: [String] { storage.withLock { $0 } }
    }

    @Test func captionAndReportWaitForTheDeferredFinish() async throws {
        let temp = try TempDatabase()
        let database = temp.database
        let source = try await FixtureVideo.make(in: temp.directory.url)
        let videoID = try await database.registerVideo(hash: UUID().uuidString, filename: source.lastPathComponent,
            path: source.path, duration: 3, width: 720, height: 1280, wide: false)
        _ = try await database.saveAnalysis(videoID: videoID, runName: "Fixture", instructions: "", sampleInterval: nil,
            notesJSON: nil, tagRanges: ["fixture": [(start: 0, end: 1.5), (start: 1.5, end: 3)]], moments: [],
            analyzedTags: ["fixture"], provider: nil, model: nil, mode: "visual")
        let projectID = try await database.createProject(profileName: "Express", name: "Deferred", videoIDs: [videoID])
        let scenes = try await database.fetchScenes(projectID: projectID)
        #expect(scenes.count == 2)

        var profile = Fixtures.brand(name: "Express")
        profile.outputFolder = temp.directory.url.appendingPathComponent("outputs").path
        var options = WizardOptions()
        options.projectID = projectID
        options.critiqueLoop = false
        options.useMusic = false
        options.addCaptions = false
        options.includeWatermark = false
        options.includeOutro = false
        options.enableTextOverlays = false
        options.podcastFraming = .original
        options.allowedTransitions = ["cut"]
        let plan = Fixtures.plan(clips: scenes.map { WizardPlanClip(sceneID: $0.id, start: $0.startTime, end: $0.endTime) })
        let take = try await database.recordWizardTake(projectID: projectID, options: options.step1, plan: plan)

        let captionCalls = Lines()
        var config = AIConfig()
        config.tasks["captions"] = "claude"
        config.providers["claude"] = AIProviderSettings(bin: "/bin/echo", model: "fixture")
        let ai = AIService(config: config) { _, _, stdin, _, _, _ in
            captionCalls.append(String(decoding: stdin ?? Data(), as: UTF8.self))
            let response = try JSONSerialization.data(withJSONObject: [
                "type": "assistant", "message": ["content": [["type": "text", "text": "Deferred caption #fixture"]]],
            ])
            return ProcessResult(stdout: response, stderr: Data(), exitCode: 0)
        }
        let engine = WizardEngine(ai: ai, render: RenderEngine())
        let renderLog = Lines()
        // Express asks for every caption before the first render; the reel reuses its request.
        let captions = await engine.startCaptionRequests(takes: [take], options: options, profile: profile,
                                                         database: database) { _, line in renderLog.append(line) }
        #expect(captions.keys.contains(take.id))
        let finish = try await engine.makeReel(take: take, options: options, profile: profile, database: database,
                                               batchID: "batch", deferFinish: true, captionRequest: captions[take.id],
                                               emit: { renderLog.append($0) })
        let deferred = try #require(finish)

        // The file and its record exist; the caption was requested during the
        // render (it needs only the plan) but is written by the finish.
        let rendered = try #require(try await database.fetchGeneratedVideos(projectID: projectID).first)
        #expect(FileManager.default.fileExists(atPath: rendered.path))
        #expect(rendered.caption.isEmpty)
        #expect(captionCalls.all.count == 1)  // the prestarted request, not a second one
        #expect(captionCalls.all.first?.contains("Duration: 3s") == true)
        #expect(renderLog.all.contains { $0.hasPrefix("Caption — asking the model") })
        let renderStages = renderLog.all.compactMap(WizardTiming.parse).map(\.stage)
        #expect(renderStages.contains("extract clips") && renderStages.contains("join clips"))
        #expect(renderStages.contains("quality gate") && renderStages.contains("save record"))
        #expect(renderStages.contains("render"))
        #expect(!renderStages.contains("social caption") && !renderStages.contains("reel traits"))
        #expect(!renderLog.all.contains { $0.hasPrefix("VIDEO:") })
        #expect(try await database.reelTraits(kind: "generated", videoID: String(rendered.id)) == nil)

        let finishLog = Lines()
        try await deferred { finishLog.append($0) }
        #expect(captionCalls.all.count == 1)
        let finished = try #require(try await database.fetchGeneratedVideos(projectID: projectID).first)
        #expect(finished.caption == "Deferred caption #fixture")
        let finishStages = finishLog.all.compactMap(WizardTiming.parse).map(\.stage)
        #expect(finishStages == ["social caption", "reel traits", "run report"])
        // The traits were recorded in the finish and carry the caption.
        let traits = try #require(try await database.reelTraits(kind: "generated", videoID: String(finished.id)))
        #expect(traits.captionLength == "Deferred caption #fixture".count && traits.hashtagCount == 1)
        #expect(finishLog.all.contains { $0.hasPrefix("VIDEO:") })
        #expect(finishLog.all.last?.hasPrefix("Video complete!") == true)
        // The run report sits next to the video and carries the render log too.
        let report = URL(fileURLWithPath: rendered.path).deletingPathExtension().appendingPathExtension("md")
        let reportText = try String(contentsOf: report, encoding: .utf8)
        #expect(reportText.contains("Deferred caption #fixture"))
        #expect(reportText.contains("Assembling"))
    }

    @Test func inlineFinishStillCompletesBeforeReturning() async throws {
        let temp = try TempDatabase()
        let database = temp.database
        let source = try await FixtureVideo.make(in: temp.directory.url)
        let videoID = try await database.registerVideo(hash: UUID().uuidString, filename: source.lastPathComponent,
            path: source.path, duration: 3, width: 720, height: 1280, wide: false)
        _ = try await database.saveAnalysis(videoID: videoID, runName: "Fixture", instructions: "", sampleInterval: nil,
            notesJSON: nil, tagRanges: ["fixture": [(start: 0, end: 2)]], moments: [],
            analyzedTags: ["fixture"], provider: nil, model: nil, mode: "visual")
        let projectID = try await database.createProject(profileName: "Express", name: "Inline", videoIDs: [videoID])
        let scene = try #require(try await database.fetchScenes(projectID: projectID).first)
        var profile = Fixtures.brand(name: "Express")
        profile.outputFolder = temp.directory.url.appendingPathComponent("outputs").path
        var options = WizardOptions()
        options.projectID = projectID
        options.critiqueLoop = false
        options.useMusic = false
        options.addCaptions = false
        options.includeWatermark = false
        options.includeOutro = false
        options.enableTextOverlays = false
        options.podcastFraming = .original
        let take = try await database.recordWizardTake(projectID: projectID, options: options.step1,
            plan: Fixtures.plan(clips: [WizardPlanClip(sceneID: scene.id, start: 0, end: 2)]))
        // The caption model is down: the failure is logged and the reel stays.
        var config = AIConfig()
        config.tasks["captions"] = "claude"
        config.providers["claude"] = AIProviderSettings(bin: "/bin/echo", model: "fixture")
        let ai = AIService(config: config) { _, _, _, _, _, _ in throw AIError.unusableResponse("Fixture model unavailable") }
        let engine = WizardEngine(ai: ai, render: RenderEngine())
        let log = Lines()
        let finish = try await engine.makeReel(take: take, options: options, profile: profile, database: database,
                                               emit: { log.append($0) })
        #expect(finish == nil)
        let lines = log.all
        #expect(lines.contains { $0.hasPrefix("Caption generation failed") })
        #expect(lines.contains { $0.hasPrefix("VIDEO:") })
        let stages = lines.compactMap(WizardTiming.parse).map(\.stage)
        #expect(stages.contains("render") && stages.contains("social caption") && stages.contains("run report"))
        #expect(stages.contains("reel traits"))
        #expect(try await database.fetchGeneratedVideos(projectID: projectID).count == 1)
    }
}
