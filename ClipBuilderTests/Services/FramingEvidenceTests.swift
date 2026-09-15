import Foundation
import Testing
import Synchronization
@testable import Clip_Builder

@Suite("Framing evidence reuse", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable, "Install ffmpeg and ffprobe to run."))
struct FramingEvidenceTests {
    @Test("people are detected once per sampled frame and shared across callers")
    func humanBoxesDetectOncePerFrame() async throws {
        let temp = try TempDirectory()
        let source = try await FixtureVideo.make(in: temp.url, wide: true)
        let cache = SampledFrameCache()
        let first = try await cache.humanBoxes(url: source, at: [0.5, 1.5], maxDimension: 720)
        #expect(first.count == 2)
        #expect(first.allSatisfy { $0 != nil })
        #expect(await cache.visionRequests == 2)
        let second = try await cache.humanBoxes(url: source, at: [0.5, 1.5, 2.5], maxDimension: 720)
        #expect(await cache.visionRequests == 3)
        #expect(second[0] == first[0] && second[1] == first[1])
        // A different sample size is different evidence.
        _ = try await cache.humanBoxes(url: source, at: [0.5], maxDimension: 360)
        #expect(await cache.visionRequests == 4)
        // Portrait fit and the framing pass share the same three moments.
        let fit = await Analyzer.portraitFit(url: source, start: 0, end: 3, videoWidth: 1920, videoHeight: 1080,
                                             frameCache: cache)
        #expect(fit?.fit == .noPeople)
        let afterFit = await cache.visionRequests
        _ = await Analyzer.portraitFit(url: source, start: 0, end: 3, videoWidth: 1920, videoHeight: 1080,
                                       frameCache: cache)
        #expect(await cache.visionRequests == afterFit)
        let job = Task { try await cache.humanBoxes(url: source, at: [2.0], maxDimension: 720) }
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
    }

    @Test("a moving camera without framed: tags samples no frames; the static camera still does")
    func trackedCameraSkipsSamples() async throws {
        let temp = try TempDatabase()
        let source = try await FixtureVideo.make(in: temp.directory.url, wide: true)
        let videoID = try await temp.database.registerVideo(
            hash: "framing-evidence", filename: source.lastPathComponent, path: source.path,
            duration: 3, width: 1920, height: 1080, wide: true)
        _ = try await temp.database.saveAnalysis(
            videoID: videoID, runName: "Fixture", instructions: "", sampleInterval: 1,
            notesJSON: nil, tagRanges: ["fixture": [(start: 0, end: 3)]], moments: [],
            analyzedTags: ["fixture"], provider: nil, model: nil, mode: "visual")
        let video = try #require(try await temp.database.fetchVideos().first)
        let cache = SampledFrameCache()
        let messages = Mutex<[String]>([])
        try await SampledFrameCache.$current.withValue(cache) {
            _ = try await FramingService.detectFraming(video: video, database: temp.database, camera: "balanced",
                tagFramedPeople: false, log: { line in messages.withLock { $0.append(line) } })
            #expect(await cache.visionRequests == 0)
            #expect(messages.withLock { $0.contains("Framing: skipped evidence samples for 1 tracked scene(s) without framed: tags") })
            messages.withLock { $0.removeAll() }
            _ = try await FramingService.detectFraming(video: video, database: temp.database,
                camera: FramingService.staticCamera, tagFramedPeople: false,
                log: { line in messages.withLock { $0.append(line) } })
            #expect(await cache.visionRequests == 3)
            #expect(!messages.withLock { $0.contains { $0.hasPrefix("Framing: skipped evidence samples") } })
            // Tagging needs the samples even with a moving camera; they are cached now.
            _ = try await FramingService.detectFraming(video: video, database: temp.database, camera: "balanced",
                tagFramedPeople: true, log: { line in messages.withLock { $0.append(line) } })
            #expect(await cache.visionRequests == 3)
        }
    }
}
