import Foundation
import Testing
@testable import Clip_Builder

struct DubMixerTests {
    @Test func trackUsesSilenceTempoDelayAndUnnormalizedMix() {
        let line = DubLine(clipUID: UUID(), speakerKey: "unknown", voice: "voice", text: "Olá",
            sourceStart: 0, sourceEnd: 1, start: 1.25, duration: 1, stretch: 1.1, audio: "line.caf")
        #expect(DubMixer.trackFilter(lines: [line], duration: 4) ==
            "[0:a]atrim=duration=4.000000,asetpts=PTS-STARTPTS[bed];" +
            "[1:a]asetpts=PTS-STARTPTS,atempo=1.100000,aresample=48000,aformat=channel_layouts=stereo,adelay=1250:all=1[line0];" +
            "[bed][line0]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]")
        #expect(DubMixer.trackFilter(lines: [], duration: 4) ==
            "[0:a]atrim=duration=4.000000,asetpts=PTS-STARTPTS[bed];" +
            "[bed]amix=inputs=1:duration=first:dropout_transition=0:normalize=0[aout]")
    }

    @Test func overlayDucksOnlyLineWindowsWithPointFifteenRamps() {
        let line = DubLine(clipUID: UUID(), speakerKey: "unknown", voice: "voice", text: "Hello",
            sourceStart: 0, sourceEnd: 2, start: 1, duration: 2)
        var settings = DubSettings(language: "en-US")
        let envelope = "max(0\\,min(1\\,min((t-0.850000)/0.150000\\,(3.150000-t)/0.150000)))"
        #expect(DubMixer.overlayFilter(lines: [line], settings: settings) ==
            "[0:a]volume='1-0.850000*(\(envelope))':eval=frame[orig];" +
            "[orig][1:a]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]")
        settings.replaceOriginal = true
        #expect(DubMixer.overlayFilter(lines: [line], settings: settings).contains("1-1.000000*"))
    }

    @Test func renderWindowRebasesSpeechAndTrimsElapsedAudioBeforeTempo() throws {
        let clip = Fixtures.timelineClip(sourceStart: 0, duration: 10)
        var document = Fixtures.timelineDocument(clips: [clip])
        document.dub = DubSettings(language: "en-US")
        document.dubLines = [1.0, 4.0, 8.0].map { start in
            DubLine(clipUID: clip.uid, speakerKey: "unknown", voice: "voice", text: "Hello",
                sourceStart: start, sourceEnd: start + 2, start: start, duration: 2, stretch: 1.1)
        }
        let window = MultitrackRenderer.windowed(document, from: 2, to: 7)
        let lines = try #require(window.dubLines)
        #expect(lines.map(\.start) == [-1, 2])
        #expect(DubMixer.trackFilter(lines: lines, duration: 5).contains(
            "[1:a]atrim=start=1.100000,asetpts=PTS-STARTPTS,atempo=1.100000"))
        #expect(DubMixer.trackFilter(lines: lines, duration: 5).contains("adelay=0:all=1[line0]"))
    }

    @Test func dubSettingsAndEveryReviewedRenderInputInvalidateBothCaches() throws {
        let line = DubLine(clipUID: UUID(), speakerKey: "host", voice: "voice", text: "Hello",
            sourceStart: 0, sourceEnd: 2, start: 1, duration: 2, audio: "line.caf")
        var input = RenderFinishingKey(segments: ["one", "two"], transitions: [nil], transitionDuration: 0.3,
            overlays: [], settings: RenderSettings(), encoder: [], dub: DubSettings(language: "en-US"), dubLines: [line])
        let changes: [(inout RenderFinishingKey) -> Void] = [
            { $0.dub?.enabled = false }, { $0.dub?.language = "pt-BR" },
            { $0.dub?.originalLevel = 0.3 }, { $0.dub?.replaceOriginal = true },
            { $0.dub?.voices["host"] = "other" }, { $0.dubLines?[0].text = "Goodbye" },
            { $0.dubLines?[0].voice = "other" }, { $0.dubLines?[0].rate = 1.2 },
            { $0.dubLines?[0].stretch = 1.1 }, { $0.dubLines?[0].start = 2 },
            { $0.dubLines?[0].duration = 3 }, { $0.dubLines?[0].audio = "other.caf" },
        ]
        for version in ["multitrack-assembly-v1", "multitrack-finishing-v1"] {
            let original = try RenderSegmentCache.key(input, version: version)
            for change in changes {
                var edited = input; change(&edited)
                #expect(try RenderSegmentCache.key(edited, version: version) != original)
            }
        }
        input.dub = nil; input.dubLines = nil
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        #expect(json["dub"] == nil && json["dubLines"] == nil)
    }
}
