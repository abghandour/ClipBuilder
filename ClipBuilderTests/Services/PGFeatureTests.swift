import Foundation
import Testing

@testable import Clip_Builder

@Suite("Peace Grappler feature foundations")
struct PGFeatureTests {
    @Test("output presets resolve expected canvases")
    func outputPresets() {
        #expect(RenderSettings(preset: .portrait1080).width == 1080)
        #expect(RenderSettings(preset: .portrait1080).height == 1920)
        #expect(RenderSettings(preset: .landscape4K).width == 3840)
        #expect(RenderSettings(preset: .landscape4K).height == 2160)
        #expect(RenderSettings(preset: .feedPortrait1080).height == 1350)
        #expect(RenderSettings(preset: .custom, customWidth: 1234, customHeight: 777).height == 776)
    }

    @Test("explicit cadence produces a shaped ruler")
    func pacingMarkers() throws {
        let steady = EditPacing(cadence: .twoSeconds, curve: .steady).markers(until: 10)
        #expect(steady == [2, 4, 6, 8])

        let accelerating = EditPacing(cadence: .threeSeconds, curve: .accelerate)
            .markers(until: 18)
        #expect(try #require(accelerating.first) > 3)
        #expect(try #require(accelerating.last) - accelerating[accelerating.count - 2] < 3)
    }

    @Test("transcript analysis proposes configurable silence and filler cuts")
    func transcriptCleanup() {
        let result = TranscriptFeatureAnalyzer.analyze(
            segments: [
                .init(start: 2, end: 3, text: "Um", words: nil),
                .init(start: 3.2, end: 5, text: "Here is the real point", words: nil),
            ],
            videoID: 9, speakerKeys: ["alex", "sam"], mediaDuration: 7,
            speakerHints: [.init(startTime: 3, endTime: 5.2, personKey: "sam")],
            deadAirThreshold: 1.5, fillerRunThreshold: 2
        )

        #expect(result.proposals.contains { $0.kind == .silence && $0.startTime == 0 && $0.endTime == 2 })
        #expect(result.proposals.contains { $0.kind == .filler && $0.startTime == 2 })
        #expect(result.features.contains { $0.kind == .speech && $0.energy > 0 })
        #expect(result.features.contains { $0.kind == .speech && $0.speakerKey == "sam" })
    }

    @Test("regression: a stored camera path only replays on the canvas it was framed for")
    func cameraPathCanvasCheck() {
        // A 9:16 crop of a 16:9 source: normalized width 0.316, full height.
        let portrait = [CameraPathKeyframe(t: 0, x: 0.3, y: 0, w: 9.0 / 16 * 9.0 / 16, h: 1),
                        CameraPathKeyframe(t: 1, x: 0.35, y: 0, w: 9.0 / 16 * 9.0 / 16, h: 1)]
        #expect(CenterStageService.pathMatchesCanvas(portrait, canvasAspect: 9.0 / 16))
        #expect(!CenterStageService.pathMatchesCanvas(portrait, canvasAspect: 16.0 / 9))
        #expect(!CenterStageService.pathMatchesCanvas(portrait, canvasAspect: 1))
        // The same crop of a square source is nearly square.
        #expect(CenterStageService.pathMatchesCanvas(portrait, sourceSize: CGSize(width: 1, height: 1),
                                                     canvasAspect: 9.0 / 16 * 9.0 / 16))
        #expect(!CenterStageService.pathMatchesCanvas([], canvasAspect: 9.0 / 16))
    }

    @Test("quality presets encode with VideoToolbox at a canvas-scaled bitrate; custom CRF uses x264")
    func encoderSelection() async {
        var balanced = RenderSettings(preset: .portrait1080)
        balanced.quality = .balanced
        let hd = await RenderContext.$settings.withValue(balanced) { FFmpeg.videoEncodeArgs }
        var balanced4K = RenderSettings(preset: .portrait4K)
        balanced4K.quality = .balanced
        let uhd = await RenderContext.$settings.withValue(balanced4K) { FFmpeg.videoEncodeArgs }
        if FFmpeg.hasVideoToolbox {
            #expect(hd.contains("h264_videotoolbox"))
            #expect(hd.contains("8M"))          // the bitrate the app always used at 1080×1920
            #expect(uhd.contains("33M"))        // four times the pixels
        } else {
            #expect(hd.contains("libx264"))
        }
        var custom = RenderSettings(preset: .portrait1080)
        custom.quality = .custom
        custom.customCRF = 18
        let crf = await RenderContext.$settings.withValue(custom) { FFmpeg.videoEncodeArgs }
        #expect(crf.contains("libx264"))
        #expect(crf.contains("18"))
        #expect(!crf.contains("h264_videotoolbox"))
    }

    @Test("topic segmentation honors long pauses and preserves source ranges")
    func topicSegmentation() {
        let features = [
            TranscriptFeatureSegment(
                id: 0, videoID: 4, startTime: 0, endTime: 5,
                text: "How did camp change you?", speakerKey: "host",
                energy: 0.8, kind: .speech),
            TranscriptFeatureSegment(
                id: 0, videoID: 4, startTime: 5.2, endTime: 18,
                text: "The main adjustment was recovery", speakerKey: "guest",
                energy: 0.7, kind: .speech),
            TranscriptFeatureSegment(
                id: 0, videoID: 4, startTime: 22, endTime: 30,
                text: "Now let us discuss the matchup", speakerKey: "host",
                energy: 0.6, kind: .speech),
        ]

        let topics = TopicSegmenter.segment(features, videoID: 4)
        #expect(topics.count == 2)
        #expect(topics[0].startTime == 0)
        #expect(topics[0].endTime == 18)
        #expect(topics[1].startTime == 22)
        #expect(!topics[0].title.isEmpty)
    }
}
