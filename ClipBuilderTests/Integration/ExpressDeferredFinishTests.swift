import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

/// Express hands each reel's traits and report back as deferred work so it
/// can overlap the next render. This renders one short real reel, checks the
/// finish, and writes the post text on demand afterwards.
@Suite("Express deferred finish", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable, "Install ffmpeg and ffprobe to run."))
struct ExpressDeferredFinishTests {
    private final class Lines: Sendable {
        private let storage = Mutex<[String]>([])
        func append(_ line: String) { storage.withLock { $0.append(line) } }
        var all: [String] { storage.withLock { $0 } }
    }

    @Test func captionAndReportWaitForTheDeferredFinish() async throws {
        let temp = try await TempDatabase()
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
        options.framing = Framing(subject: .original)
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
        let finish = try await engine.makeReel(take: take, options: options, profile: profile, database: database,
                                               batchID: "batch", deferFinish: true,
                                               emit: { renderLog.append($0) })
        let deferred = try #require(finish)
        // The file and its record exist; no post text was asked for.
        let rendered = try #require(try await database.fetchGeneratedVideos(projectID: projectID).first)
        #expect(rendered.caption.isEmpty)
        #expect(captionCalls.all.isEmpty)
        #expect(!renderLog.all.contains { $0.hasPrefix("VIDEO:") })
        let renderStages = renderLog.all.compactMap(WizardTiming.parse).map(\.stage)
        #expect(renderStages.contains("render"))
        #expect(!renderStages.contains("reel traits") && !renderStages.contains("run report"))

        let finishLog = Lines()
        try await deferred { finishLog.append($0) }
        #expect(captionCalls.all.isEmpty, "the finish writes no post text either")
        #expect(finishLog.all.contains { $0.hasPrefix("VIDEO:") })
        let finishStages = finishLog.all.compactMap(WizardTiming.parse).map(\.stage)
        #expect(finishStages == ["reel traits", "run report"])
        let traits = try #require(try await database.reelTraits(kind: "generated", videoID: String(rendered.id)))
        #expect(traits.captionLength == 0 && traits.hashtagCount == 0)

        // On demand, after the video exists: the text lands on the record and in the traits.
        let writeLog = Lines()
        let response = try await engine.writePostText(video: rendered, note: nil, options: options, profile: profile,
                                                      database: database, emit: { writeLog.append($0) })
        #expect(response.text == "Deferred caption #fixture")
        #expect(captionCalls.all.count == 1)
        #expect(captionCalls.all.first?.contains("Duration: 3s") == true)
        #expect(captionCalls.all.first?.contains("This is a rewrite") == false)
        let written = try #require(try await database.fetchGeneratedVideos(projectID: projectID).first)
        #expect(written.caption == "Deferred caption #fixture")
        let updated = try #require(try await database.reelTraits(kind: "generated", videoID: String(rendered.id)))
        #expect(updated.captionLength == "Deferred caption #fixture".count && updated.hashtagCount == 1)
        #expect(writeLog.all.compactMap(WizardTiming.parse).map(\.stage) == ["post text"])
        // A rewrite carries the previous text and the steer.
        _ = try await engine.writePostText(video: written, note: "shorter", options: options, profile: profile,
                                           database: database, emit: { _ in })
        #expect(captionCalls.all.count == 2)
        let rewrite = try #require(captionCalls.all.last)
        #expect(rewrite.contains("This is a rewrite") && rewrite.contains("Deferred caption #fixture") && rewrite.contains("shorter"))
    }

    @Test func inlineFinishStillCompletesBeforeReturning() async throws {
        let temp = try await TempDatabase()
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
        options.framing = Framing(subject: .original)
        let take = try await database.recordWizardTake(projectID: projectID, options: options.step1,
            plan: Fixtures.plan(clips: [WizardPlanClip(sceneID: scene.id, start: 0, end: 2)]))
        // No model is reachable: the render needs none and the reel stays.
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
        #expect(!lines.contains { $0.contains("asking the model") })
        #expect(lines.contains { $0.hasPrefix("VIDEO:") })
        let stages = lines.compactMap(WizardTiming.parse).map(\.stage)
        #expect(stages.contains("render") && stages.contains("run report") && stages.contains("reel traits"))
        #expect(!stages.contains("social caption") && !stages.contains("caption wait"))
        #expect(try await database.fetchGeneratedVideos(projectID: projectID).count == 1)
    }
}
