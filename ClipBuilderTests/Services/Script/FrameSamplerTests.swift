import Foundation
import Testing
@testable import Clip_Builder

@Suite("Frame sampling for the agent", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable, "Install ffmpeg and ffprobe to run."))
struct FrameSamplerTests {
    @Test("frames come back scaled, optionally cropped, with detection rows and images the coordinator can lift")
    func samplesAndCrops() async throws {
        let temp = try TempDirectory()
        let source = try await FixtureVideo.make(in: temp.url, wide: true)
        var video = Fixtures.video()
        video.path = source.path
        video.duration = 3
        let whole = try await FrameSampler.sample(.init(video: 1, times: [0.5, 2.5], size: 320), video: video, roster: [])
        #expect(whole.frames.count == 2 && whole.images.count == 2)
        #expect(whole.frames.map(\.time) == [0.5, 2.5])
        #expect(whole.frames.allSatisfy { $0.width == 320 && $0.height == 180 })
        #expect(whole.images.allSatisfy { $0.mimeType == "image/jpeg" && Data(base64Encoded: $0.data) != nil })
        // A crop keeps the crop's shape; boxes stay in full-frame fractions.
        let cropped = try await FrameSampler.sample(
            .init(video: 1, times: [1], crop: .init(x: 0.25, y: 0, w: 0.28125, h: 1), size: 256), video: video, roster: [])
        let frame = try #require(cropped.frames.first)
        #expect(frame.height == 256 && abs(Double(frame.width) / Double(frame.height) - 0.5) < 0.02)
        #expect(cropped.crop == .init(x: 0.25, y: 0, w: 0.28125, h: 1))
        // Validation.
        #expect(throws: (any Error).self) { try FrameSampler.validate(.init(video: 1, times: []), duration: 3) }
        #expect(throws: (any Error).self) { try FrameSampler.validate(.init(video: 1, times: [4]), duration: 3) }
        #expect(throws: (any Error).self) { try FrameSampler.validate(.init(video: 1, times: [1], crop: .init(x: 0.9, y: 0, w: 0.5, h: 1)), duration: 3) }
        #expect(throws: (any Error).self) { try FrameSampler.validate(.init(video: 1, times: [1], size: 64), duration: 3) }
        #expect(throws: (any Error).self) { try FrameSampler.validate(.init(video: 1, times: Array(repeating: 1, count: 13)), duration: 3) }
    }

    @Test("the sample_frames tool serves project videos only and hides in author mode")
    @MainActor
    func toolGating() async throws {
        let temp = try TempDirectory()
        let source = try await FixtureVideo.make(in: temp.url, wide: true)
        var library = ScriptFixtures.library()
        library.videos[0].path = source.path
        library.videos[0].duration = 3
        let session = BuilderScriptSession(live: ScriptFixtures.model(), library: library)
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()))
        #expect(tools.definitions.contains { $0.name == "sample_frames" })
        let data = try await tools.call(name: "sample_frames", arguments: ["video": .int(1), "times": .array([.double(1)]), "size": .int(200)])
        let result = try JSONDecoder().decode(FrameSampler.Result.self, from: data)
        #expect(result.frames.count == 1 && result.images.count == 1 && result.size == 200)
        await #expect(throws: (any Error).self) {
            try await tools.call(name: "sample_frames", arguments: ["video": .int(99), "times": .array([.double(1)])])
        }
        await #expect(throws: (any Error).self) {
            try await tools.call(name: "sample_frames", arguments: ["video": .int(1), "times": .array([.double(1)]), "extra": .int(1)])
        }
        let author = BuilderTools(session: BuilderScriptSession(live: ScriptFixtures.model(), library: library),
                                  budget: BuilderRunBudget(.init()), mode: .author)
        #expect(!author.definitions.contains { $0.name == "sample_frames" })
        let find = BuilderTools(session: BuilderScriptSession(live: ScriptFixtures.model(), library: library),
                                budget: BuilderRunBudget(.init()), mode: .find)
        #expect(find.definitions.contains { $0.name == "sample_frames" })
    }
}
