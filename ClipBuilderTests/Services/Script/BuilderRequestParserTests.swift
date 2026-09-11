import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Builder request parser")
struct BuilderRequestParserTests {
    private func context() -> ParserContext {
        let model = ScriptFixtures.model()
        model.selection = .clip(model.document.videoTrack[0].uid)
        var library = ScriptFixtures.library()
        library.tags = ["fixture", "wide shot"]
        library.people = [PersonRecord(id: 1, key: "alex_key", name: "Alex Smith", descriptor: "")]
        library.scenes[0].tags += ["person:alex_key"]
        return ParserContext(library: library, model: model)
    }

    private func transcript(video: Int64 = 1) -> TranscriptRow {
        TranscriptRow(id: video, videoID: video, language: "en", isTranslation: false,
                      startTime: 2, endTime: 6, text: "fixture", originalText: nil,
                      wordsJSON: nil, provider: "fake", model: "fake")
    }

    private func steps(_ text: String, _ context: ParserContext) throws -> [BuilderScriptStep] {
        guard case .script(let steps) = BuilderRequestParser().parse(text, context: context) else {
            Issue.record("Expected script for \(text)")
            throw ScriptError.invalid("Not a script")
        }
        return steps
    }

    @Test(arguments: ["remove clips with Alex Smith", "remove all clips with Alex Smith",
                      "remove scenes with Alex Smith", "remove all scenes with Alex Smith"])
    func removePerson(_ request: String) throws {
        let context = context()
        var expected = ClipFilter(); expected.people = ["alex_key"]
        #expect(try steps(request, context) == [.init(.removeClips(filter: expected))])
    }

    @Test(arguments: ["I", "II", "1", "2", "track 2"])
    func trackAliases(_ alias: String) throws {
        var context = context(); context.document.trackCount = 2
        let lane = ["I", "1"].contains(alias) ? 0 : 1
        var expected = ClipFilter(); expected.tags = ["wide shot"]; expected.track = lane
        #expect(try steps("remove clips tagged wide shot on \(alias)", context) == [.init(.removeClips(filter: expected))])
        var unqualified = ClipFilter(); unqualified.tags = ["fixture"]
        #expect(try steps("remove clips tagged fixture", context) == [.init(.removeClips(filter: unqualified))])
    }

    @Test(arguments: ["find Alex Smith fixture", "find scenes of Alex Smith fixture"])
    func find(_ request: String) {
        var filter = SceneFilter(); filter.people = ["alex_key"]; filter.tags = ["fixture"]
        #expect(BuilderRequestParser().parse(request, context: context()) == .find(filter, presentation: request))
    }

    @Test(arguments: ["0:12", "12s", "the playhead"])
    func brollAndTime(_ time: String) throws {
        var context = context(); context.document.trackCount = 2; context.playhead = 12
        #expect(try steps("add b-roll of fixture at \(time) on track 2 for 3 s", context)
                == [.init(.addCutaway(scene: 1, at: 12, track: 1, duration: 3, coverAll: false))])
        #expect(try steps("add b-roll of fixture at \(time)", context)
                == [.init(.addCutaway(scene: 1, at: 12, track: 0, coverAll: false))])
    }

    @Test func selectionCommands() throws {
        let context = context()
        let id = try #require(context.selectedClipID).uuidString
        #expect(try steps("split this clip at 0:02", context) == [.init(.splitClip(clip: id, at: 2))])
        #expect(try steps("trim this clip to 2 s", context) == [.init(.trimClip(clip: id, duration: 2))])
        #expect(try steps("mute this clip", context) == [.init(.setClipMuted(clip: id, muted: true))])
        #expect(try steps("unmute this clip", context) == [.init(.setClipMuted(clip: id, muted: false))])
        #expect(try steps("cover all areas", context) == [.init(.setCutawayCoverAll(clip: id, coverAll: true))])
    }

    @Test(arguments: ["remove clips with Alex Smith except the first", "remove clips with Alex Smith and add titles",
                      "remove clips tagged not fixture", "find Alex Smith fixture please", "find nobody fixture",
                      "don't remove clips with Alex Smith", "remove clips tagged unknown", "remove clips tagged fixture on track 9",
                      "mute this clip and trim it", "cover all areas except II", "split this clip at 0:99",
                      "add b-roll of fixture at 12s without audio", "trim this clip to -2 s"])
    func rejectsResidualOrUnknown(_ request: String) {
        guard case .unrecognised(let reasons) = BuilderRequestParser().parse(request, context: context()) else {
            Issue.record("Partially recognised \(request)"); return
        }
        #expect(!reasons.isEmpty)
    }

    @Test func noSelectionAndAmbiguity() {
        var context = context(); context.selectedClipID = nil
        for text in ["mute this clip", "split this clip at 2s", "trim this clip to 2s", "cut silence in this clip", "cover all areas"] {
            guard case .unrecognised(let reasons) = BuilderRequestParser().parse(text, context: context) else {
                Issue.record("Accepted missing selection"); continue
            }
            #expect(reasons.contains { $0.contains("Select a clip") })
        }
        context.library.people.append(PersonRecord(id: 2, key: "other", name: "Alex Smith", descriptor: ""))
        guard case .unrecognised(let reasons) = BuilderRequestParser().parse("remove clips with Alex Smith", context: context) else {
            Issue.record("Accepted ambiguous name"); return
        }
        #expect(reasons.first?.contains("Ambiguous") == true)
    }

    @Test(arguments: ["cut silence in this clip", "remove silence longer than 0.3 s in this clip",
                      "cut silence on track 1", "remove silence longer than 0.3 s on track I"])
    func silenceExpansion(_ request: String) throws {
        var context = context()
        context.library.transcripts = [transcript()]
        context.library.features = [TranscriptFeatureSegment(id: 1, videoID: 1, startTime: 3, endTime: 4,
                                                               text: "", speakerKey: nil, energy: 0, kind: .silence)]
        let id = try #require(context.selectedClipID).uuidString
        let program = try steps(request, context)
        #expect(program == [
            .init(.splitClip(clip: id, at: 1, precision: .speech), bind: "silence_0"),
            .init(.splitClip(clip: "$silence_0.tail", at: 2, precision: .speech), bind: "silence_1"),
            .init(.removeClip(clip: "$silence_0.tail"))
        ])
        let model = ScriptFixtures.model(clips: context.document.videoTrack)
        let session = BuilderScriptSession(live: model, library: context.library)
        #expect(session.run(program).completed)
        session.freeze()
        #expect(session.candidate?.videoTrack.count == 2)
        #expect(session.candidate?.videoTrack.map(\.sourceStart) == [2, 4])
    }

    @Test func missingTranscriptDefersDistinctVideosInOrder() throws {
        var context = context()
        let parser = BuilderRequestParser()
        #expect(parser.parse("cut silence in this clip", context: context)
                == .deferred(prerequisites: [.init(.ensureTranscript(video: 1))]))
        var secondVideo = Fixtures.video(); secondVideo.id = 2; secondVideo.path = "/tmp/second.mp4"
        context.library.videos.append(secondVideo)
        var secondClip = Fixtures.timelineClip(sceneID: nil, startTime: 4)
        secondClip.videoFile = secondVideo.path
        context.document.videoTrack.insert(secondClip, at: 0)
        context.document.videoTrack.append(Fixtures.timelineClip(startTime: 8))
        #expect(parser.parse("cut silence on track 1", context: context)
                == .deferred(prerequisites: [.init(.ensureTranscript(video: 1)), .init(.ensureTranscript(video: 2))]))
        context.library.transcripts = [transcript(video: 2)]
        #expect(parser.parse("cut silence on track 1", context: context)
                == .deferred(prerequisites: [.init(.ensureTranscript(video: 1))]))
        for request in ["cut silence on track 1 except the first", "don't cut silence on track 1",
                        "cut silence on track 1 and mute it", "cut silence on track 6"] {
            guard case .unrecognised = parser.parse(request, context: context) else {
                Issue.record("Deferred a request without full recognition: \(request)"); continue
            }
        }
        context = self.context()
        context.library.transcripts = [transcript()]
        guard case .unrecognised(let reasons) = parser.parse("cut silence in this clip", context: context) else {
            Issue.record("Untimed rows must not imply silence"); return
        }
        #expect(reasons.contains { $0.contains("evidence is unavailable") })
    }

    @Test func newCommandsRoundTripAndRoleRules() throws {
        let model = ScriptFixtures.model()
        let id = model.document.videoTrack[0].uid.uuidString
        let commands: [BuilderScriptStep] = [.init(.setClipMuted(clip: id, muted: true)),
                                             .init(.setCutawayCoverAll(clip: id, coverAll: true))]
        #expect(try ScriptRunner.decode(JSONEncoder().encode(commands)) == commands)
        let session = BuilderScriptSession(live: model, library: ScriptFixtures.library())
        #expect(!session.run(commands).completed)
        #expect(session.state == .failed && session.candidate == nil)
        var clip = model.document.videoTrack[0]; clip.role = .cutaway
        let cutaway = ScriptFixtures.session(clips: [clip])
        #expect(cutaway.run([.init(.setClipMuted(clip: id, muted: false)), commands[1]]).completed)
        cutaway.freeze()
        #expect(cutaway.candidate?.videoTrack.first?.cutawayAudio == .mixed)
        #expect(cutaway.candidate?.videoTrack.first?.coverAllAreas == true)
    }
    @Test func speedAdjustedSilenceAndSliverRefusal() throws {
        let clip = Fixtures.timelineClip(sourceStart: 0, duration: 4, speed: 2)
        let model = ScriptFixtures.model(clips: [clip])
        model.selection = .clip(clip.uid)
        var library = ScriptFixtures.library()
        library.transcripts = [transcript()]
        library.features = [TranscriptFeatureSegment(id: 1, videoID: 1, startTime: 2, endTime: 4,
                                                     text: "", speakerKey: nil, energy: 0, kind: .silence)]
        var context = ParserContext(library: library, model: model)
        let program = try steps("cut silence longer than 0.5 s in this clip", context)
        let session = BuilderScriptSession(live: model, library: library)
        #expect(session.run(program).completed)
        session.freeze()
        #expect(session.candidate?.videoTrack.map(\.sourceStart) == [0, 4])
        #expect(session.candidate?.videoTrack.map(\.duration) == [1, 2])
        context.library.features[0].startTime = 0.02
        guard case .unrecognised(let reasons) = BuilderRequestParser().parse("cut silence in this clip", context: context) else {
            Issue.record("Accepted a sub-50 ms survivor"); return
        }
        #expect(reasons.contains { $0.contains("50 ms") })
    }

    @Test func distinctMultiwordEntitiesAndVocabularyScope() {
        var context = context()
        var filter = SceneFilter(); filter.tags = ["wide shot"]
        #expect(BuilderRequestParser().parse("find wide shot", context: context) == .find(filter, presentation: "find wide shot"))
        context.library.scenes[0].tags.append("scene-only-tag")
        guard case .unrecognised = BuilderRequestParser().parse("find scene-only-tag", context: context) else {
            Issue.record("Resolved a tag outside the profile vocabulary"); return
        }
        context.library.people[0].hidden = true
        guard case .unrecognised = BuilderRequestParser().parse("find Alex Smith", context: context) else {
            Issue.record("Resolved a hidden roster entry"); return
        }
    }

}
