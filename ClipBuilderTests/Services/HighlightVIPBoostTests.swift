import Testing
@testable import Clip_Builder

struct HighlightVIPBoostTests {
    @Test func scenesPreferVIPOnlyOnEqualScore() {
        var host = Fixtures.scene(id: 1)
        host.score = 8
        var guest = host
        guest.id = 2
        var strongest = host
        strongest.id = 3
        strongest.score = 9
        #expect(HighlightVIPBoost.rankedScenes([host, guest, strongest], vipSceneIDs: [2]).map(\.id) == [3, 2, 1])
    }

    @Test func boostAndCap() {
        #expect(HighlightVIPBoost.adjusted(score: 7, speakerKeys: ["host"], vipKeys: ["guest"], talkShare: [:]) == 7)
        #expect(HighlightVIPBoost.adjusted(score: 7, speakerKeys: ["guest"], vipKeys: ["guest"], talkShare: ["guest": 0.2]) == 8.5)
        #expect(HighlightVIPBoost.adjusted(score: 7, speakerKeys: ["guest"], vipKeys: ["guest"], talkShare: ["guest": 0.5]) == 9)
        #expect(HighlightVIPBoost.adjusted(score: 9, speakerKeys: ["guest"], vipKeys: ["guest"], talkShare: ["guest": 1]) == 10)
        #expect(HighlightVIPBoost.adjusted(score: 7, speakerKeys: ["guest"], vipKeys: [], talkShare: ["guest": 1]) == 7)
    }
}
