import Foundation
import Testing
@testable import Clip_Builder

@Suite("Podcast highlight B-roll bounds")
struct PodcastHighlightBRollTests {
    @Test func singleReelSpacingUsesAbsoluteTimesAcrossSpans() {
        typealias Cut = PodcastHighlightBRollPlanner.Cut
        let cuts = [
            [Cut(source: .scene(1), sourceStart: 50, start: 7, duration: 3, reason: "End of first span")],
            [Cut(source: .scene(2), sourceStart: 80, start: 0, duration: 1, reason: "Too close"),
             Cut(source: .scene(2), sourceStart: 90, start: 2, duration: 2, reason: "Exactly two seconds")]
        ]
        let spaced = WizardPodcastBRoll.spacedCuts(cuts, offsets: [0, 10])
        #expect(spaced[0] == cuts[0])
        #expect(spaced[1] == [cuts[1][1]])
        let separated = WizardPodcastBRoll.spacedCuts(cuts, offsets: [0, 12])
        #expect(separated[1] == [cuts[1][0]])
        #expect(WizardPodcastBRoll.spacedCuts([], offsets: []).isEmpty)
    }

    private var sources: PodcastHighlightBRollPlanner.Sources {
        .init(videoID: 1, range: 10...40, people: ["guest", "host"])
    }
    private var candidate: HighlightCandidate {
        HighlightCandidate(sourceStart: 10, sourceEnd: 40, title: "Learning grappling", reason: "Training changes everything.",
                           score: 8, kind: .whole, speakerKeys: ["guest"])
    }
    private var turns: [SpeakerTurn] {
        [.init(videoID: 1, start: 10, end: 25, cluster: 0, confidence: 1, personKey: "guest", tile: 0),
         .init(videoID: 1, start: 25, end: 29, cluster: 1, confidence: 1, personKey: "host", tile: 1),
         .init(videoID: 1, start: 29, end: 40, cluster: 0, confidence: 1, personKey: "guest", tile: 0)]
    }
    private var tiles: [PodcastTile] {
        [.init(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "guest"),
         .init(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "host")]
    }
    private var speech: [TranscriptSegment] {
        [.init(start: 10, end: 40, text: "Speech.", words: nil)]
    }

    @Test func protectsHookAndLimitsSpeechWithGaps() {
        let cuts = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
                                                     segments: speech, tiles: tiles, scenes: [], threshold: 7)
        #expect(!cuts.isEmpty)
        #expect(cuts.allSatisfy { $0.start >= 2 && $0.duration <= 3 && $0.start + $0.duration <= candidate.duration })
        #expect(zip(cuts, cuts.dropFirst()).allSatisfy { $1.start >= $0.start + $0.duration + 2 })
        #expect(cuts.contains { $0.reason == "Listener's turn" && $0.start == 15 })
        for cut in cuts {
            if case .reaction(let tile) = cut.source {
                let turn = turns.first { $0.start <= cut.sourceStart && $0.end > cut.sourceStart }
                #expect(tile != turn?.tile)
            }
        }
    }

    @Test func listenerWindowWinsOverNearbySpeech() {
        let turns = [SpeakerTurn(videoID: 1, start: 10, end: 14, cluster: 1, confidence: 1, personKey: "host", tile: 1),
                     SpeakerTurn(videoID: 1, start: 14, end: 40, cluster: 0, confidence: 1, personKey: "guest", tile: 0)]
        let cuts = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
                                                     segments: speech, tiles: tiles, scenes: [], threshold: 7)
        #expect(cuts.first?.start == 2)
        #expect(cuts.first?.reason == "Listener's turn")
    }

    @Test func relatedScenesOnlyAndNoSourcesMeansNoCutaways() {
        var scene = Fixtures.scene(id: 2, start: 3, end: 5)
        scene.videoID = 2; scene.tags = ["person:guest"]
        var unrelated = Fixtures.scene(id: 3)
        unrelated.videoID = 3; unrelated.tags = ["unrelated"]
        #expect(PodcastHighlightBRollPlanner.matchingScenes(sources: sources, scenes: [scene, unrelated], threshold: 7).map(\.id) == [2])
        let cuts = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
                                                     segments: speech, tiles: [], scenes: [scene], threshold: 7)
        #expect(!cuts.isEmpty && cuts.allSatisfy { $0.source == .scene(2) && $0.duration <= 2 })
        #expect(PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
                                                 segments: speech, tiles: [], scenes: [unrelated], threshold: 7).isEmpty)
        scene.tags = ["grappling", "training"]
        #expect(PodcastHighlightBRollPlanner.matchingScenes(sources: sources, scenes: [scene], threshold: 7).isEmpty)
    }

    @Test func sideBySideTurnsAndSilentGapsCanUseReactions() {
        var sideTurns = turns
        for index in sideTurns.indices {
            sideTurns[index].resolvedSide = sideTurns[index].tile == 0 ? .left : .right
            sideTurns[index].tile = nil
            sideTurns[index].personKey = nil
        }
        let cuts = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: sideTurns,
                                                     segments: speech, tiles: tiles, scenes: [], threshold: 7)
        #expect(!cuts.isEmpty)
        let pauseTurns = [SpeakerTurn(videoID: 1, start: 10, end: 13, cluster: 0, confidence: 1, tile: 0),
                          SpeakerTurn(videoID: 1, start: 16, end: 40, cluster: 1, confidence: 1, tile: 1)]
        let segments = [TranscriptSegment(start: 10, end: 13, text: "Before.", words: nil),
                        TranscriptSegment(start: 16, end: 40, text: "After.", words: nil)]
        let pauses = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: pauseTurns,
                                                       segments: segments, tiles: tiles, scenes: [], threshold: 7)
        #expect(pauses.first?.start == 3 && pauses.first?.reason == "Pause")
    }

    @Test func pausesArePreferred() {
        let segments = [TranscriptSegment(start: 10, end: 13, text: "Before.", words: nil),
                        TranscriptSegment(start: 16, end: 40, text: "After.", words: nil)]
        let cuts = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
                                                     segments: segments, tiles: tiles, scenes: [], threshold: 7)
        #expect(cuts.first?.start == 3 && cuts.first?.reason == "Pause")
    }
    @Test func matchingRequiresPersonOrOwnRecordingAndThreshold() {
        var scene = Fixtures.scene(id: 2)
        scene.videoID = 2
        // Topic words alone never bring a stranger's footage into a reel.
        scene.tags = ["grappling", "training"]
        #expect(PodcastHighlightBRollPlanner.matchingScenes(sources: sources, scenes: [scene], threshold: 7).isEmpty)
        scene.tags = ["person:guest"]
        #expect(PodcastHighlightBRollPlanner.matchingScenes(sources: sources, scenes: [scene], threshold: 8).count == 1)
        #expect(PodcastHighlightBRollPlanner.matchingScenes(sources: sources, scenes: [scene], threshold: 8.1).isEmpty)
        scene.score = nil
        #expect(PodcastHighlightBRollPlanner.matchingScenes(sources: sources, scenes: [scene], threshold: 7).isEmpty)
        scene.score = 8
        scene.tags = ["person:stranger"]
        #expect(PodcastHighlightBRollPlanner.matchingScenes(sources: sources, scenes: [scene], threshold: 7).isEmpty)
        // The reel's own recording qualifies at another moment, never at the one on screen.
        var own = Fixtures.scene(id: 3, start: 50, end: 55)
        own.videoID = 1
        #expect(PodcastHighlightBRollPlanner.matchingScenes(sources: sources, scenes: [own], threshold: 7).map(\.id) == [3])
        own.startTime = 35; own.endTime = 45
        #expect(PodcastHighlightBRollPlanner.matchingScenes(sources: sources, scenes: [own], threshold: 7).isEmpty)
        // Someone the reel names counts as in context.
        var named = sources
        named.mentioned = ["conor-mcgregor"]
        var about = Fixtures.scene(id: 4)
        about.videoID = 3
        about.tags = ["person:conor-mcgregor"]
        #expect(PodcastHighlightBRollPlanner.matchingScenes(sources: named, scenes: [about], threshold: 7).count == 1)
        #expect(PodcastHighlightBRollPlanner.matchingScenes(sources: sources, scenes: [about], threshold: 7).isEmpty)
    }

    @Test func mentionedPeopleAndSourcesComeFromNamesTurnsTagsAndSpeech() {
        let people = [PersonRecord(id: 1, key: "conor-mcgregor", name: "", descriptor: ""),
                      PersonRecord(id: 2, key: "person-2", name: "", descriptor: ""),
                      PersonRecord(id: 3, key: "max", name: "Max Holloway", descriptor: "")]
        let roster = [VideoPersonRecord(videoID: 1, personID: 4, key: "guest", name: "Guest Name", descriptor: "", portraitAt: 0, portraitBox: nil)]
        let names = PodcastHighlightBRollPlanner.personNames(people, roster: roster)
        #expect(names["person-2"] == nil && names["conor-mcgregor"] == "Conor Mcgregor" && names["guest"] == "Guest Name")
        #expect(PodcastHighlightBRollPlanner.mentionedPeople(in: "I fought Conor's team.", names: names) == ["conor-mcgregor"])
        #expect(PodcastHighlightBRollPlanner.mentionedPeople(in: "Max is tough.", names: names).isEmpty)
        #expect(PodcastHighlightBRollPlanner.mentionedPeople(in: "MAX HOLLOWAY is tough.", names: names) == ["max"])
        #expect(PodcastHighlightBRollPlanner.mentionedPeople(in: "That person over there.", names: names).isEmpty)
        var tagged = Fixtures.scene(id: 7, start: 10, end: 40)
        tagged.videoID = 1
        tagged.tags = ["podcast-exchange", "person:producer"]
        let segments = [TranscriptSegment(start: 12, end: 20, text: "We talked to Conor McGregor.", words: nil),
                        TranscriptSegment(start: 50, end: 60, text: "Max Holloway came later.", words: nil)]
        let built = PodcastHighlightBRollPlanner.sources(videoID: 1, range: 10...40, speakerKeys: ["guest"], turns: turns,
            roster: [], scenes: [tagged], segments: segments, people: people)
        #expect(built.people == ["guest", "host", "producer"])
        #expect(built.mentioned == ["conor-mcgregor"] && built.recordings == [1])
        let merged = PodcastHighlightBRollPlanner.Sources(merging: [built, .init(videoID: 2, range: 0...5, people: ["conor-mcgregor"])])
        #expect(merged.recordings == [1, 2] && merged.mentioned.isEmpty && merged.people.contains("conor-mcgregor"))
    }

    @Test func offeredScenesAreInContextAndOtherRecordingsRankFirst() {
        var own = Fixtures.scene(id: 5, start: 50, end: 55)
        own.videoID = 1
        own.score = 9
        var stranger = Fixtures.scene(id: 6)
        stranger.videoID = 9
        stranger.score = 10
        stranger.tags = ["fight", "knockout"]
        // Another exchange of the same conversation is the talk itself, not footage of it.
        var exchange = Fixtures.scene(id: 8, start: 60, end: 70)
        exchange.videoID = 1
        exchange.score = 10
        exchange.tags = ["podcast", "podcast-exchange", "person:guest"]
        let offered = PodcastHighlightBRollPlanner.offeredScenes(sources: sources, scenes: [own, stranger, exchange, footage], instructions: "")
        #expect(offered.map(\.id) == [2, 5])
        #expect(sources.label(for: footage, names: ["guest": "Guest Name"]) == "shows Guest Name")
        #expect(sources.label(for: own, names: [:]) == "same recording, another moment")
        #expect(PodcastHighlightBRollPlanner.offeredScenes(sources: sources, scenes: [own, footage], instructions: "only reactions").isEmpty)
        let cuts = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
            segments: speech, tiles: [], scenes: [stranger], threshold: 7, instructions: "no reactions")
        #expect(cuts.isEmpty)
    }

    @Test func earliestCutUsesReactionBeforeRelatedFootage() {
        var scene = Fixtures.scene(id: 2, start: 0, end: 10)
        scene.videoID = 2; scene.tags = ["person:guest"]
        let cuts = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
            segments: speech, tiles: tiles, scenes: [scene], threshold: 7)
        #expect(cuts.first?.source == .reaction(tile: 1))
        #expect(cuts.contains { $0.source == .scene(2) })
    }

    @Test func reactionsRotateAndTotalBudgetIsFortyPercent() {
        let third = PodcastTile(index: 2, x: 0, y: 0, w: 0.5, h: 1, personKey: "other")
        let turns = [SpeakerTurn(videoID: 1, start: 10, end: 40, cluster: 0, confidence: 1, tile: 0)]
        let rows = stride(from: 10, to: 40, by: 5).map {
            TranscriptSegment(start: Double($0), end: Double($0 + 5), text: "Sentence.", words: nil)
        }
        let cuts = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
            segments: rows, tiles: tiles + [third], scenes: [], threshold: 7)
        #expect(cuts.map(\.source) == [.reaction(tile: 1), .reaction(tile: 2), .reaction(tile: 1), .reaction(tile: 2)])
        #expect(cuts.reduce(0) { $0 + $1.duration } <= candidate.duration * 0.4)
        var short = candidate
        short.sourceEnd = 15
        let shortCuts = PodcastHighlightBRollPlanner.plan(candidate: short, sources: sources, turns: turns,
            segments: rows, tiles: tiles, scenes: [], threshold: 7)
        #expect(shortCuts.reduce(0) { $0 + $1.duration } == 2)
    }


    private var placementRows: [TranscriptSegment] {
        stride(from: 10, to: 40, by: 5).map { .init(start: Double($0), end: Double($0 + 5), text: "Sentence.", words: nil) }
    }

    private var footage: SceneRecord {
        var scene = Fixtures.scene(id: 2, start: 3, end: 20)
        scene.videoID = 2
        scene.tags = ["person:guest"]
        return scene
    }

    @Test func validatesAIPlacementHookLengthOverlapBudgetAndSourceIDs() {
        typealias Placement = PodcastHighlightBRollPlanner.Placement
        let suggestions = [Placement(firstSentence: 0, lastSentence: 0, source: "scene:2", reason: "Hook, rejected"),
                           Placement(firstSentence: 1, lastSentence: 2, source: "scene:2", reason: "Long, clamped"),
                           Placement(firstSentence: 1, lastSentence: 1, source: "scene:2", reason: "Overlap, rejected"),
                           Placement(firstSentence: 2, lastSentence: 2, source: "scene:999", reason: "Unknown, rejected")]
        let cuts = PodcastHighlightBRollPlanner.validated(placements: suggestions, candidate: candidate,
            sentences: placementRows, sources: sources, turns: turns, tiles: tiles, scenes: [footage])
        #expect(cuts.count == 1 && cuts.first?.start == 5 && cuts.first?.duration == 3)
        let many = (1..<6).map { Placement(firstSentence: $0, lastSentence: $0, source: "scene:2", reason: "Footage") }
        let bounded = PodcastHighlightBRollPlanner.validated(placements: many, candidate: candidate,
            sentences: placementRows, sources: sources, turns: turns, tiles: tiles, scenes: [footage])
        var short = candidate
        short.sourceEnd = 24
        let partial = PodcastHighlightBRollPlanner.validated(placements: many, candidate: short,
            sentences: placementRows, sources: sources, turns: turns, tiles: tiles, scenes: [footage])
        #expect(abs(partial.reduce(0) { $0 + $1.duration } - short.duration * 0.4) < 0.001)
        #expect(bounded.count == 4)
        #expect(bounded.reduce(0) { $0 + $1.duration } == candidate.duration * 0.4)
        let bad = [Placement(firstSentence: -1, lastSentence: 1, source: "scene:2", reason: "Bad index"),
                   Placement(firstSentence: 1, lastSentence: 1, source: "reaction:guest", reason: "Speaking"),
                   Placement(firstSentence: 1, lastSentence: 1, source: "reaction:unknown", reason: "Unknown")]
        #expect(PodcastHighlightBRollPlanner.validated(placements: bad, candidate: candidate,
            sentences: placementRows, sources: sources, turns: turns, tiles: tiles, scenes: [footage]).isEmpty)
        let reaction = [Placement(firstSentence: 1, lastSentence: 1, source: "reaction:host", reason: "Listener")]
        #expect(PodcastHighlightBRollPlanner.validated(placements: reaction, candidate: candidate,
            sentences: placementRows, sources: sources, turns: turns, tiles: tiles, scenes: []).first?.source == .reaction(tile: 1))
    }

    @Test func instructionHintsRestrictDeterministicSources() {
        let external = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
            segments: placementRows, tiles: tiles, scenes: [footage], threshold: 7, instructions: "NO REACTIONS")
        #expect(!external.isEmpty && external.allSatisfy { $0.source == .scene(2) })
        for hint in ["no external", "only reactions"] {
            let reactions = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
                segments: placementRows, tiles: tiles, scenes: [footage], threshold: 7, instructions: hint)
            #expect(!reactions.isEmpty && reactions.allSatisfy { if case .reaction = $0.source { return true }; return false })
        }
        #expect(PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
            segments: placementRows, tiles: tiles, scenes: [footage], threshold: 7,
            instructions: "no reaction; no external").isEmpty)
    }

    @Test func modelPlacementsAreUsedAloneAndInvalidResponsesFallBack() async throws {
        var video = Fixtures.video()
        video.podcastLayout = "grid"
        video.podcastTilesJSON = String(decoding: try JSONEncoder().encode(tiles), as: UTF8.self)
        var options = WizardOptions()
        options.brollInstructions = "Use footage of the guest's fights, no reaction."
        let valid = #"{"placements":[{"first_sentence":1,"last_sentence":1,"source":"scene:2","reason":"Guest fight footage"}]}"#
        let partlyValid = valid.replacingOccurrences(of: "]}", with: ", {\"first_sentence\":\"invalid\"}]}")
        var stranger = Fixtures.scene(id: 6, start: 0, end: 10)
        stranger.videoID = 9
        stranger.score = 10
        for response in [valid, partlyValid, "invalid", #"{"placements":[{"first_sentence":0,"last_sentence":0,"source":"scene:999","reason":"Invalid"}]}"#] {
            let stub = try StubAI(response: response)
            let cuts = try await PodcastHighlightBRollPlacement.plan(candidate: candidate, video: video, scenes: [footage, stranger],
                turns: turns, roster: [], segments: placementRows, options: options, ai: stub.service)
            if response == valid || response == partlyValid {
                #expect(cuts.count == 1 && cuts.first?.reason == "Guest fight footage" && cuts.first?.source == .scene(2))
            } else {
                let fallback = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources, turns: turns,
                    segments: placementRows, tiles: tiles, scenes: [footage], threshold: 7, instructions: options.brollInstructions)
                #expect(!cuts.isEmpty && cuts == fallback)
            }
            let prompt = try String(contentsOf: stub.prompts, encoding: .utf8)
            #expect(prompt.contains(options.brollInstructions) && prompt.contains("scene:2") && prompt.contains("[1]"))
            #expect(prompt.contains("shows guest") && !prompt.contains("scene:6"))
        }
        options.useBRoll = false
        let stub = try StubAI(response: valid)
        let off = try await PodcastHighlightBRollPlacement.plan(candidate: candidate, video: video, scenes: [footage],
            turns: turns, roster: [], segments: placementRows, options: options, ai: stub.service)
        #expect(off.isEmpty && !FileManager.default.fileExists(atPath: stub.calls.path))
    }

}
