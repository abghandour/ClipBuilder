import Foundation
import Testing
@testable import Clip_Builder

struct BRollCutMappingTests {
    private let cut = BRollCut(start: 105, end: 108, sceneID: 2, sceneOffset: 1, reason: "Gane", origin: .auto)

    private func candidate(kind: HighlightCandidate.Kind = .whole, start: Double = 100, end: Double = 120) -> HighlightCandidate {
        HighlightCandidate(sourceStart: start, sourceEnd: end, title: "Test", reason: "", score: 8,
                           kind: kind, speakerKeys: [])
    }

    @Test func trimKeepsWordTimesDropsOutsideAndClampsBothEdges() throws {
        #expect(BRollCutMapping.trimmed([cut], to: 101...119) == [cut])
        #expect(BRollCutMapping.trimmed([cut], to: 108...120).isEmpty)
        #expect(BRollCutMapping.trimmed([cut], to: 90...105).isEmpty)
        let clamped = try #require(BRollCutMapping.trimmed([cut], to: 106...107).first)
        #expect(clamped.id == cut.id && clamped.start == 106 && clamped.end == 107)
        #expect(clamped.sceneOffset == 2 && clamped.reason == "Gane" && clamped.origin == .auto)
    }

    @Test func mapsWholeAndSubcutClocks() throws {
        let scenes = [Fixtures.scene(id: 2, start: 50, end: 60)]
        let whole = BRollCutMapping.planned([cut], candidate: candidate(), scenes: scenes)
        #expect(whole == [.init(source: .scene(2), sourceStart: 51, start: 5, duration: 3, reason: "Gane")])
        let subcut = BRollCutMapping.planned([cut], candidate: candidate(kind: .subcut, start: 106, end: 115), scenes: scenes)
        #expect(subcut == [.init(source: .scene(2), sourceStart: 52, start: 0, duration: 2, reason: "Gane")])
        #expect(BRollCutMapping.planned([cut], candidate: candidate(), scenes: []).isEmpty)
    }

    @Test func cameraPiecesMergeButDifferentPicksStaySeparate() {
        let first = Fixtures.timelineClip(sourceStart: 100, duration: 5, startTime: 2)
        var second = Fixtures.timelineClip(sourceStart: 105, duration: 5, startTime: 7)
        second.originKey = first.originKey
        let next = Fixtures.timelineClip(sourceStart: 110, duration: 5, startTime: 12)
        let spans = BRollCutMapping.sourceSpans([next, second, first])
        #expect(spans.count == 2)
        #expect(spans[0].sourceStart == 100 && spans[0].sourceEnd == 110)
        #expect(spans[0].startTime == 2 && spans[0].duration == 10)
        #expect(spans[1].originKey == next.originKey)
    }

    @Test func optionalStoredCutsSurvivePlanJSONAndCombinedTakes() throws {
        var source = Fixtures.scene(start: 100, end: 120); source.tags = ["podcast-exchange"]
        var plan = try #require(WizardEngine.miniHighlightPlans([candidate()], videoID: 1, scenes: [source]).first)
        plan.clips[0].brollCuts = [cut]
        let restored = try JSONDecoder().decode(WizardPlan.self, from: JSONEncoder().encode(plan))
        #expect(restored.clips.first?.brollCuts == [cut])
        let take = WizardSelectionTake(id: 1, selectionID: 1, ordinal: 1, plan: restored, sceneIDs: [source.id])
        #expect(WizardPlanRules.combinedPlan([take, take]).clips.map(\.brollCuts) == [[cut], [cut]])
        var old = plan; old.clips[0].brollCuts = nil
        let oldJSON = try JSONEncoder().encode(old)
        #expect(!String(decoding: oldJSON, as: UTF8.self).contains("brollCuts"))
        #expect(try JSONDecoder().decode(WizardPlan.self, from: oldJSON).clips[0].brollCuts == nil)
        old.clips[0].brollCuts = []
        #expect(try JSONDecoder().decode(WizardPlan.self, from: JSONEncoder().encode(old)).clips[0].brollCuts == [])
    }

    @Test func renderKeyIncludesEveryStoredCutEditAndNilVersusEmpty() async throws {
        let video = Fixtures.video(), profile = Fixtures.brand()
        let request = PodcastHighlightReviewRequest(video: video, candidates: [], scenes: [], segments: [],
            turns: [], roster: [], options: WizardOptions())
        func key(_ cuts: [BRollCut]?) async throws -> String {
            var item = candidate(); item.brollCuts = cuts
            return try await PodcastHighlightRenderKey.make(candidate: item, request: request, layouts: [],
                profile: profile, tagText: [:], sourceFingerprint: "fixture")
        }
        let unplanned = try await key(nil)
        let empty = try await key([])
        #expect(unplanned != empty)
        let original = try await key([cut])
        #expect(try await key([cut]) == original)
        var foundAgain = cut; foundAgain.id = UUID()
        #expect(try await key([foundAgain]) == original)
        for field in 0..<6 {
            var edited = cut
            switch field {
            case 0: edited.start += 0.25
            case 1: edited.end -= 0.25
            case 2: edited.sceneID += 1
            case 3: edited.sceneOffset += 0.25
            case 4: edited.reason = "Jones"
            default: edited.origin = .user
            }
            #expect(try await key([edited]) != original)
        }
    }
}
