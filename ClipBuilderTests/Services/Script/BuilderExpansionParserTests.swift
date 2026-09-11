import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Expansion request phrases")
struct BuilderExpansionParserTests {
    @Test func exactPhrasesAndFullRecognition() {
        let model = ScriptFixtures.model()
        let clip = model.document.videoTrack[0].uid
        model.selection = .clip(clip)
        model.document.soundTrack = [SoundItem(name: "music")]
        let context = ParserContext(library: ScriptFixtures.library(), model: model)
        let sound = model.document.soundTrack[0].uid.uuidString
        let examples: [(String, BuilderCommand)] = [
            ("set this clip speed to 1.5x", .setClipSpeed(clip: clip.uuidString, speed: 1.5)),
            ("captions off for this clip", .setClipCaptions(clip: clip.uuidString, captions: "none")),
            ("set music volume to 2", .setSoundVolume(sound: sound, volume: 2)),
            ("set track I captions to bottom", .setTrackCaptions(track: 0, captions: "bottom")),
            ("mute track 1", .setTrackMuted(track: 0, muted: true)),
            ("unmute track I", .setTrackMuted(track: 0, muted: false))
        ]
        for (phrase, command) in examples {
            #expect(BuilderRequestParser().parse(phrase, context: context) == .script([.init(command)]))
            for invalid in [phrase + " except the first", phrase + " and delete it", "don't " + phrase] {
                guard case .unrecognised = BuilderRequestParser().parse(invalid, context: context) else {
                    Issue.record("Must consume the full request: \(invalid)"); continue
                }
            }
        }
        for invalid in ["set this clip speed to 5x", "set music volume to 0", "set track 1 volume to 3",
                        "set track 1 captions to inherit", "set music volume to 2.5"] {
            guard case .unrecognised = BuilderRequestParser().parse(invalid, context: context) else {
                Issue.record("Invalid or unavailable setting accepted: \(invalid)"); continue
            }
        }
    }

    @Test func musicNeedsExactlyOneSoundAndSelectionIsRequired() {
        let model = ScriptFixtures.model()
        for sounds in [[], [SoundItem(), SoundItem()]] {
            model.document.soundTrack = sounds
            let context = ParserContext(library: ScriptFixtures.library(), model: model)
            guard case .unrecognised = BuilderRequestParser().parse("set music volume to 2", context: context) else {
                Issue.record("Music reference is ambiguous or absent"); continue
            }
        }
        model.selection = nil
        let context = ParserContext(library: ScriptFixtures.library(), model: model)
        for phrase in ["set this clip speed to 1.5x", "captions off for this clip"] {
            guard case .unrecognised = BuilderRequestParser().parse(phrase, context: context) else {
                Issue.record("Selection is required"); continue
            }
        }
    }
}
