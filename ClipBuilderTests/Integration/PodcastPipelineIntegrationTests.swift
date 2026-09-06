import Foundation
import Testing
@testable import Clip_Builder

@Suite("Podcast pipeline integration", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable,
                "Install ffmpeg and ffprobe to run."))
struct PodcastPipelineIntegrationTests {
    @Test("synthetic alternating speakers resolve to profile people")
    func diarizationAndIdentity() async throws {
        let temp = try TempDirectory(prefix: "ClipBuilderPodcastTest")
        let url = try await FixtureVideo.makePodcast(in: temp.url)
        var video = Fixtures.video()
        video.path = url.path
        video.duration = 4
        video.videoType = VideoType.podcast.rawValue
        let segments = (0..<4).map { index in
            TranscriptSegment(start: Double(index), end: Double(index + 1),
                              text: index.isMultiple(of: 2) ? "Question?" : "Answer.", words: nil)
        }
        let turns = try await PodcastSpeakerSeparator.separate(video: video, segments: segments)
        #expect(Set(turns.map(\.cluster)).count == 2)

        let roster = [
            VideoPersonRecord(videoID: 1, personID: 1, key: "host", name: "Host",
                              descriptor: "host", portraitAt: 0,
                              portraitBox: .init(x: 0.1, y: 0.1, w: 0.3, h: 0.7)),
            VideoPersonRecord(videoID: 1, personID: 2, key: "guest", name: "Guest",
                              descriptor: "guest", portraitAt: 0,
                              portraitBox: .init(x: 0.6, y: 0.1, w: 0.3, h: 0.7)),
        ]
        let picture = turns.enumerated().map { index, turn in
            PictureTalkerSignal(start: turn.start, end: turn.end,
                                side: index.isMultiple(of: 2) ? .left : .right,
                                confidence: 0.95)
        }
        let resolved = PodcastSpeakerTimelineResolver.resolve(
            audioTurns: turns, picture: picture, layout: .splitHorizontal,
            roster: roster, minimumHold: 0)
        #expect(Set(resolved.compactMap(\.personKey)) == Set(["host", "guest"]))
    }

    @Test("split Zoom render is vertical and keeps audio")
    func splitRender() async throws {
        let temp = try TempDirectory(prefix: "ClipBuilderPodcastSplitTest")
        let source = try await FixtureVideo.makePodcast(in: temp.url)
        let output = temp.url.appendingPathComponent("split.mp4")
        try await PodcastFramingService.splitZoom(source: source, start: 0,
                                                  duration: 2, output: output)
        let dimensions = await FFmpeg.dimensions(of: output)
        #expect(dimensions.width == 1080)
        #expect(dimensions.height == 1920)
        #expect(await FFmpeg.hasAudioStream(output))
    }

    @Test("a center seam without faces does not classify as Zoom")
    func layoutNeedsFacesAndSeam() async throws {
        let temp = try TempDirectory(prefix: "ClipBuilderPodcastLayoutTest")
        let source = try await FixtureVideo.makePodcast(in: temp.url)
        let jpeg = try #require(await ThumbnailService.jpegFrame(url: source, at: 1))
        #expect(await PodcastVisualAnalyzer.hasCenterSeam(jpeg))
        var video = Fixtures.video()
        video.path = source.path
        video.duration = 4
        let visual = await PodcastVisualAnalyzer.analyze(video: video, turns: [])
        #expect(visual.layout == .singleCamera)
        #expect(visual.seamX == nil)
    }
}
