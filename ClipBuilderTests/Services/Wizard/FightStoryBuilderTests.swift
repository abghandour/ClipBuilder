import Foundation
import Testing
@testable import Clip_Builder

@Suite("Fight story builder")
struct FightStoryBuilderTests {
    private func scene(_ id: Int64, video: Int64, _ start: Double, _ end: Double) -> SceneRecord {
        var scene = Fixtures.scene(id: id, start: start, end: end)
        scene.videoID = video
        scene.videoPath = "/tmp/video-\(video).mp4"
        scene.videoDuration = 120
        return scene
    }

    private func video(_ id: Int64, duration: Double = 120) -> VideoRecord {
        var video = Fixtures.video(id: id)
        video.duration = duration
        video.path = "/tmp/video-\(id).mp4"
        return video
    }

    private func fightPick(_ id: Int64, _ start: Double, _ end: Double, events: [Int64]) -> FightPick {
        FightPick(id: id, videoID: 2, position: Int(id), start: start, end: end, originalStart: start,
                  originalEnd: end, eventIDs: events, sceneID: nil)
    }

    private func input(fight: [FightPick]? = nil, stat: StrikeStatPayload? = nil,
                       outcome: FightOutcome? = nil, fightDuration: Double = 120) -> FightStoryBuilder.Input {
        let claim = TranscriptPick(id: 7, videoID: 1, position: 0, start: 10, end: 14,
                                   originalStart: 10, originalEnd: 14, sceneID: nil)
        let picks = fight ?? [fightPick(21, 30, 33, events: [101, 102]), fightPick(22, 50, 52, events: [103])]
        var scenes: [Int64: SceneRecord] = [:]
        for (index, pick) in picks.enumerated() {
            scenes[pick.id] = scene(Int64(200 + index), video: 2, pick.start, pick.end)
        }
        let backdrop = FightStoryBuilder.backdropRange(fight: picks, videoDuration: fightDuration, cardDuration: 2.5)
        let research = FightResearchRecord(id: 1, videoID: 2, fightLabel: "A vs B", event: "UFC 330",
                                           fightDate: "", summaryJSON: #"{"story":{"hook_line":"He said it would end early."}}"#,
                                           sourcesJSON: "[]")
        return FightStoryBuilder.Input(
            claim: claim, claimScene: scene(100, video: 1, 10, 14), claimVideo: video(1),
            fight: picks, fightScenes: scenes, fightVideo: video(2, duration: fightDuration),
            outcome: outcome, research: research,
            card: .init(kicker: "UFC 330", headline: "A wins by KO", subline: "Round 1"),
            stat: stat, claimText: "I will finish him in the first",
            backdropScene: scene(300, video: 2, backdrop.lowerBound, backdrop.upperBound))
    }

    @Test func clipsRunClaimThenFightInPickOrderThenCardRippled() {
        let document = FightStoryBuilder.build(input(), renderSettings: RenderSettings())
        #expect(document.videoTrack.map(\.sceneID) == [100, 200, 201, 300])
        #expect(document.videoTrack.map(\.startTime) == [0, 4, 7, 9])
        #expect(document.videoTrack.map(\.duration) == [4, 3, 2, 2.5])
        #expect(document.videoTrack.map(\.sourceStart) == [10, 30, 50, 52])
        #expect(document.videoTrack.allSatisfy { $0.track == 0 })
    }

    @Test func everyClipAndTheCardCarryProvenance() throws {
        let document = FightStoryBuilder.build(input(outcome: outcome()), renderSettings: RenderSettings())
        let kinds = document.videoTrack.compactMap(\.provenance?.kind)
        #expect(kinds == [.transcript, .fightAction, .fightAction, .outcome])
        let claim = try #require(document.videoTrack[0].provenance)
        #expect(claim.transcriptPickID == 7 && claim.videoID == 1)
        #expect(claim.sourceStart == 10 && claim.sourceEnd == 14)
        #expect(claim.label == "I will finish him in the first")
        let first = try #require(document.videoTrack[1].provenance)
        #expect(first.fightPickID == 21 && first.eventIDs == [101, 102] && first.videoID == 2)
        let card = try #require(document.textOverlays.first)
        #expect(card.provenance?.kind == .outcome)
        #expect(card.provenance?.researchVideoID == 2)
        #expect(card.provenance?.label == "A vs B")
        #expect(document.videoTrack[3].provenance?.sourceStart == 52)
    }

    @Test func cardCoversTheTrailingBackdropForItsDuration() throws {
        let document = FightStoryBuilder.build(input(), renderSettings: RenderSettings())
        let card = try #require(document.textOverlays.first)
        #expect(card.design == "hero")
        #expect(card.kicker == "UFC 330")
        #expect(card.text == "A wins by KO\nRound 1")
        #expect(card.startTime == 9 && card.endTime == 11.5)
        let end = document.videoTrack.map { $0.startTime + $0.duration }.max()
        #expect(end == card.endTime)
        let backdrop = try #require(document.videoTrack.last)
        #expect(backdrop.effect == FightStoryBuilder.backdropEffect)
        #expect(backdrop.captions == "none")
        #expect(document.textOverlays.count == 1)
    }

    @Test func backdropAvoidsPickedFootage() {
        let picks = [fightPick(1, 30, 33, events: []), fightPick(2, 50, 52, events: [])]
        #expect(FightStoryBuilder.backdropRange(fight: picks, videoDuration: 120, cardDuration: 2.5) == 52...54.5)
        // Picks run to the end: the longest free stretch elsewhere.
        let tight = [fightPick(1, 0, 20, events: []), fightPick(2, 25, 60, events: [])]
        #expect(FightStoryBuilder.backdropRange(fight: tight, videoDuration: 60, cardDuration: 2.5) == 20...22.5)
        // No free footage at all: the tail of the last pick, trimmed off it.
        let full = [fightPick(1, 0, 10, events: [])]
        #expect(FightStoryBuilder.backdropPlan(fight: full, videoDuration: 10, cardDuration: 2.5)
                == .init(range: 7.5...10, trimsLastPick: true, allowsStat: true))
        // A last pick shorter than two cards keeps its clip and drops the stat card.
        let short = [fightPick(1, 0, 4, events: [])]
        #expect(FightStoryBuilder.backdropPlan(fight: short, videoDuration: 4, cardDuration: 2.5)
                == .init(range: 1.5...4, trimsLastPick: false, allowsStat: false))
    }

    private func stat() -> StrikeStatPayload {
        StrikeStatPayload(kind: .roundCard, sourceVideoID: 2, sourceTime: 0,
                          values: .init(fighters: [.init(key: "a", name: "A", strikes: 12)]))
    }

    @Test func noFreeFootageTrimsTheLastPickForTheBackdrop() throws {
        // Picks cover the whole 60 s fight video; the last pick (25...60) gives up its tail.
        let picks = [fightPick(21, 0, 25, events: []), fightPick(22, 25, 60, events: [])]
        let document = FightStoryBuilder.build(input(fight: picks, stat: stat(), fightDuration: 60),
                                               renderSettings: RenderSettings())
        let lastFight = document.videoTrack[2]
        #expect(lastFight.sourceStart == 25 && lastFight.sourceEnd == 57.5)
        #expect(lastFight.duration == 32.5)
        let backdrop = try #require(document.videoTrack.last)
        #expect(backdrop.sourceStart == 57.5 && backdrop.sourceEnd == 60)
        #expect(backdrop.startTime == lastFight.startTime + lastFight.duration)
        // The stat card binds to the backdrop and maps onto it alone.
        let item = try #require(document.textOverlays.first { $0.stat != nil })
        #expect(item.stat?.sourceTime == 57.5)
        var scenes = Array(input(fight: picks, fightDuration: 60).fightScenes.values)
        scenes.append(scene(300, video: 2, 57.5, 60))
        let mapped = StrikeStatSourceBinding.mapped(item, clips: document.videoTrack, scenes: scenes, videos: [])
        #expect(mapped.map(\.startTime) == [backdrop.startTime])
    }

    @Test func shortLastPickKeepsItsClipAndOmitsTheStatCard() throws {
        // Picks cover the whole 30 s fight video; the last pick (26...30) is under 2 × 2.5 s.
        let picks = [fightPick(21, 0, 26, events: []), fightPick(22, 26, 30, events: [])]
        let document = FightStoryBuilder.build(input(fight: picks, stat: stat(), fightDuration: 30),
                                               renderSettings: RenderSettings())
        let lastFight = document.videoTrack[2]
        #expect(lastFight.sourceStart == 26 && lastFight.sourceEnd == 30)
        let backdrop = try #require(document.videoTrack.last)
        #expect(backdrop.sourceStart == 27.5 && backdrop.sourceEnd == 30)
        // The headline card stays; the stat card is left out.
        #expect(document.textOverlays.count == 1)
        #expect(document.textOverlays.allSatisfy { $0.stat == nil })
        #expect(document.textOverlays.first?.design == "hero")
    }

    @Test func statPassesThroughBoundToTheBackdrop() throws {
        let stat = StrikeStatPayload(kind: .roundCard, sourceVideoID: 2, sourceTime: 0,
                                     values: .init(fighters: [.init(key: "a", name: "A", strikes: 12)]))
        let document = FightStoryBuilder.build(input(stat: stat), renderSettings: RenderSettings())
        #expect(document.textOverlays.count == 2)
        let item = try #require(document.textOverlays.first { $0.stat != nil })
        #expect(item.stat?.values == stat.values)
        #expect(item.stat?.sourceTime == 52)
        #expect(item.design == StrikeStatPayload.Kind.roundCard.rawValue)
        #expect(item.provenance?.kind == .research)
        // The stat maps onto the backdrop clip only, not onto a picked fight clip.
        var scenes = Array(input().fightScenes.values)
        scenes.append(scene(300, video: 2, 52, 54.5))
        let mapped = StrikeStatSourceBinding.mapped(item, clips: document.videoTrack, scenes: scenes, videos: [])
        #expect(mapped.map(\.startTime) == [9])
    }

    private func outcome(method: String = "ko", round: Int? = 1) -> FightOutcome {
        FightOutcome(id: 1, videoID: 2, runID: 1, method: method, winnerKey: "jan-blachowicz",
                     loserKey: "carlos-ulberg", event: nil, round: round)
    }

    @Test func fallbackCardComesFromOutcomeAndResearch() {
        let research = FightResearchRecord(id: 1, videoID: 2, fightLabel: "A vs B", event: "UFC 330",
                                           fightDate: "", summaryJSON: #"{"story":{"hook_line":"Nobody saw it coming"}}"#,
                                           sourcesJSON: "[]")
        let card = FightStoryBuilder.fallbackCard(outcome: outcome(), research: research, fightLabel: "A vs B")
        #expect(card.kicker == "UFC 330")
        #expect(card.headline == "Jan Blachowicz wins by KO in Round 1")
        #expect(card.subline == "Nobody saw it coming")
        let named = FightStoryBuilder.fallbackCard(outcome: outcome(method: "decision", round: 3), research: nil,
                                                   fightLabel: "A vs B", names: ["jan-blachowicz": "Blachowicz"])
        #expect(named.kicker == "A VS B")
        #expect(named.headline == "Blachowicz wins by decision")
        #expect(named.subline == nil)
        let noOutcome = FightStoryBuilder.fallbackCard(outcome: nil, research: research, fightLabel: "A vs B")
        #expect(noOutcome.headline == "Nobody saw it coming")
    }

    @Test func parsesTheModelsCard() {
        let card = FightStoryBuilder.parseCard("```json\n{\"kicker\":\"UFC 330\",\"headline\":\"Done in one\",\"subline\":\"\"}\n```")
        #expect(card == .init(kicker: "UFC 330", headline: "Done in one", subline: nil))
        #expect(FightStoryBuilder.parseCard(#"{"kicker":"x","headline":" "}"#) == nil)
        #expect(FightStoryBuilder.prompt(claimText: "claim", fightLabel: "A vs B", outcome: outcome(),
                                         research: nil).contains("winner jan-blachowicz"))
    }

    @Test func provenanceRoundTripsAndOlderJSONStillDecodes() throws {
        let document = FightStoryBuilder.build(input(outcome: outcome()), renderSettings: RenderSettings())
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: data)
        #expect(decoded.videoTrack.map(\.provenance) == document.videoTrack.map(\.provenance))
        #expect(decoded.textOverlays.map(\.provenance) == document.textOverlays.map(\.provenance))

        let old = #"{"video_track":[{"type":"clip","id":5,"start_time":0,"track":0}],"text_overlays":[{"text":"Hi","start_time":0,"end_time":2}]}"#
        let legacy = try JSONDecoder().decode(TimelineDocument.self, from: Data(old.utf8))
        #expect(legacy.videoTrack.first?.provenance == nil)
        #expect(legacy.textOverlays.first?.provenance == nil)

        var a = TimelineClip()
        var b = a
        b.provenance = StoryProvenance(kind: .transcript)
        #expect(a != b)
        a.provenance = b.provenance
        #expect(a == b)
    }
}
