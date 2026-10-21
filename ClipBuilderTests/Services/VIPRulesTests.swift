import Testing
@testable import Clip_Builder

struct VIPRulesTests {
    @Test func missingAnswerUsesRulesButExplicitFalseWins() {
        let missing = VIPRules.judgement(modelValue: nil, key: "guest", fallback: ["guest"])
        #expect(missing.vip && missing.source == "rules")
        let explicit = VIPRules.judgement(modelValue: false, key: "guest", fallback: ["guest"])
        #expect(!explicit.vip && explicit.source == "ai")
        let unknown = VIPRules.judgement(modelValue: nil, key: "host", fallback: ["guest"])
        #expect(!unknown.vip && unknown.source == "rules")
    }

    @Test func firstPassSpeakingEvidenceIncludesUnidentifiedClusters() {
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 7, cluster: 0, confidence: 1),
                     SpeakerTurn(videoID: 1, start: 7, end: 10, cluster: 1, confidence: 1)]
        let evidence = VIPRules.speakingEvidence(turns: turns, transcripts: [])
        #expect(evidence.contains("unidentified speaker 1: 70%"))
        #expect(evidence.contains("unidentified speaker 2: 30%"))
    }

    @Test func unknownSpeechStillCountsInTheDenominator() {
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 2, cluster: 0, confidence: 1, personKey: "guest"),
                     SpeakerTurn(videoID: 1, start: 2, end: 10, cluster: 1, confidence: 1)]
        #expect(VIPRules.talkShare(turns: turns) == ["guest": 0.2])
        #expect(VIPRules.talkShare(turns: turns, range: 0...4) == ["guest": 0.5])
    }

    @Test func fightAndTraining() {
        let people: [(key: String, descriptor: String, category: PersonCategory?)] = [
            ("a", "Champion in red", nil), ("b", "blue shorts", .fighter), ("ref", "official", .official),
        ]
        #expect(VIPRules.fallback(videoType: .fight, people: people, talkShare: [:]) == ["a", "b"])
        #expect(VIPRules.fallback(videoType: .recap, people: people, talkShare: [:]) == ["a", "b"])
        #expect(VIPRules.fallback(videoType: .training, people: people, talkShare: [:]) == ["b"])
        #expect(VIPRules.fallback(videoType: nil, people: people, talkShare: [:]).isEmpty)
    }

    @Test func podcastHostAndMissingEvidence() {
        let people: [(key: String, descriptor: String, category: PersonCategory?)] = [
            ("host", "", nil), ("guest", "", nil), ("background", "", nil),
        ]
        #expect(VIPRules.fallback(videoType: .podcast, people: people,
                                  talkShare: ["host": 0.7, "guest": 0.3]) == ["guest"])
        #expect(VIPRules.fallback(videoType: .interview, people: people, talkShare: [:]).isEmpty)
        #expect(VIPRules.fallback(videoType: .podcast, people: people, talkShare: ["host": 1]).isEmpty)
    }
}
