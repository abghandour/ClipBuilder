import Foundation
import Testing
@testable import Clip_Builder

@Suite("Speaker cluster naming")
struct SpeakerClusterNamingTests {
    @Test("Suspicious summaries cover shared, removed, and missing names")
    func verdicts() {
        func verdict(_ clusters: Int, named namedClusters: Int? = nil, _ named: Set<String>, _ roster: Set<String>) -> SpeakerClusterNaming.Verdict {
            SpeakerClusterNaming.Summary(clusters: clusters, namedClusters: namedClusters ?? (named.isEmpty ? 0 : clusters),
                                          namedKeys: named, rosterKeys: roster, layout: .singleCamera).verdict
        }
        // The old fallback: both clusters carry the one roster person.
        #expect(verdict(2, ["aljo"], ["aljo"]).isSuspicious)
        #expect(verdict(1, ["removed"], ["aljo"]).isSuspicious)
        // Never named with one person: the re-map always names that person.
        // With several people and no name the evidence tied; a re-map would
        // produce the same map, so it is not offered again.
        #expect(verdict(2, [], ["aljo"]).isSuspicious)
        #expect(!verdict(2, [], ["aljo", "ariel"]).isSuspicious)
        #expect(!SpeakerClusterNaming.Summary(clusters: 1, namedKeys: [], rosterKeys: ["aljo"], layout: .splitHorizontal).verdict.isSuspicious)
        #expect(!verdict(1, ["aljo"], ["aljo"]).isSuspicious)
        #expect(!verdict(2, ["aljo", "ariel"], ["aljo", "ariel"]).isSuspicious)
        // Two people on screen, every line on one of them: the other one
        // spoke too, whatever the clusters say.
        #expect(verdict(2, named: 2, ["johnny"], ["johnny", "marcello"]).reasons.count == 1)
        // One voice heard, or the second voice left unnamed: not the collapse signature.
        #expect(!verdict(1, named: 1, ["johnny"], ["johnny", "marcello"]).isSuspicious)
        #expect(!verdict(2, named: 1, ["johnny"], ["johnny", "marcello"]).isSuspicious)
        #expect(SpeakerClusterNaming.Summary(clusters: 2, namedClusters: 2, namedKeys: ["johnny"],
                                             rosterKeys: ["johnny", "marcello"], layout: .splitHorizontal)
            .verdict.reason.contains("every line went to one speaker"))
        // What the resolver produces for an off-camera interviewer: the
        // dominant cluster named, the other left as Speaker 2. Not flagged,
        // otherwise the step would re-offer the same work forever.
        #expect(!verdict(2, named: 1, ["aljo"], ["aljo"]).isSuspicious)
        #expect(!verdict(3, named: 2, ["aljo", "ariel"], ["aljo", "ariel", "host"]).isSuspicious)
        #expect(!verdict(2, [], []).isSuspicious)
        #expect(!verdict(0, [], []).isSuspicious)
        #expect(!verdict(2, ["aljo"], ["aljo"]).reason.isEmpty)
    }

    @Test("People changes and suspicious maps need remapping; unchanged healthy maps do not")
    func remapping() {
        let healthy = SpeakerClusterNaming.Verdict(reasons: [])
        #expect(SpeakerClusterNaming.needsRemap(namedKeys: ["aljo"], rosterBefore: ["aljo"],
                                                rosterAfter: ["aljo", "ariel"], verdict: healthy))
        #expect(!SpeakerClusterNaming.needsRemap(namedKeys: ["aljo"], rosterBefore: ["aljo"],
                                                 rosterAfter: ["aljo"], verdict: healthy))
        #expect(SpeakerClusterNaming.needsRemap(namedKeys: ["aljo"], rosterBefore: ["aljo"],
                                                rosterAfter: ["aljo"], verdict: .init(reasons: ["Shared name"])))
        #expect(SpeakerClusterNaming.needsRemap(namedKeys: ["removed"], rosterBefore: ["aljo"],
                                                rosterAfter: ["aljo"], verdict: healthy))
    }

    @Test("Equal speech, equal visibility, and equal overlap never pick a name by order")
    func ties() {
        let turns = [SpeakerTurn(videoID: 2, start: 0, end: 10, cluster: 0, confidence: 1),
                     SpeakerTurn(videoID: 2, start: 10, end: 20, cluster: 1, confidence: 1)]
        let roster = Fixtures.aljoInterviewRoster
        #expect(assign(turns, roster).isEmpty)
        // A map with no names at all keeps the legacy roster fallback in the
        // transcript until the re-map; one named cluster turns it off.
        #expect(TranscriptSpeakers.named(turns, roster: roster).contains { $0.personKey != nil })
        var partlyNamed = turns
        partlyNamed[0].personKey = "aljo"
        #expect(TranscriptSpeakers.named(partlyNamed, roster: roster).map(\.personKey) == ["aljo", nil])
        var tied = roster
        tied[1].ranges = tied[0].ranges
        #expect(assign(Fixtures.aljoInterviewTurns, tied).isEmpty)
        var third = roster[1]
        third.key = "third"
        let overlapTie = assign(Fixtures.aljoInterviewTurns, roster + [third])
        #expect(overlapTie == [0: "aljo"])
    }

    @Test("Tracker turns no portrait named fall back to the cluster rules; named turns keep their names")
    func filling() {
        let roster = Fixtures.aljoInterviewRoster
        // What the face tracker stores when no tile matched a portrait.
        var tracked = Fixtures.aljoInterviewTurns.map { turn in
            var turn = turn
            turn.tile = turn.cluster
            turn.personKey = nil
            return turn
        }
        let filled = SpeakerClusterNaming.filling(tracked, roster: roster, layout: .singleCamera)
        #expect(filled.filter { $0.cluster == 0 }.allSatisfy { $0.personKey == "aljo" })
        #expect(filled.filter { $0.cluster == 1 }.allSatisfy { $0.personKey == "ariel" })
        // A tile the face pass named keeps its person; the other cluster
        // takes the remaining person.
        for index in tracked.indices where tracked[index].cluster == 0 { tracked[index].personKey = "ariel" }
        let kept = SpeakerClusterNaming.filling(tracked, roster: roster, layout: .singleCamera)
        #expect(kept.filter { $0.cluster == 0 }.allSatisfy { $0.personKey == "ariel" })
        #expect(kept.filter { $0.cluster == 1 }.allSatisfy { $0.personKey == "aljo" })
        // Two people visible the whole time: a tie, nothing invented.
        var tied = roster
        tied[1].ranges = tied[0].ranges
        let unnamed = tracked.map { turn in var turn = turn; turn.personKey = nil; return turn }
        #expect(SpeakerClusterNaming.filling(unnamed, roster: tied, layout: .singleCamera).allSatisfy { $0.personKey == nil })
        // One person and two equally long voices: the only person is still named once.
        let equal = [SpeakerTurn(videoID: 2, start: 0, end: 10, cluster: 0, confidence: 1),
                     SpeakerTurn(videoID: 2, start: 10, end: 20, cluster: 1, confidence: 1),
                     SpeakerTurn(videoID: 2, start: 20, end: 30, cluster: 1, confidence: 1),
                     SpeakerTurn(videoID: 2, start: 30, end: 40, cluster: 0, confidence: 1)]
        #expect(assign(equal, [roster[0]]) == [0: "aljo"])
        #expect(SpeakerClusterNaming.filling(equal, roster: roster, layout: .grid).allSatisfy { $0.personKey == nil })
    }

    @Test("Visibility coverage merges overlapping ranges and missing ranges do not invent evidence")
    func coverage() {
        var roster = Fixtures.aljoInterviewRoster
        roster[0].ranges = [0...120, 100...225.06]
        #expect(assign(Fixtures.aljoInterviewTurns, roster) == [0: "aljo", 1: "ariel"])
        roster[1].ranges = []
        #expect(assign(Fixtures.aljoInterviewTurns, roster) == [0: "aljo"])
        roster[0].ranges = []
        #expect(assign(Fixtures.aljoInterviewTurns, roster).isEmpty)
        #expect(assign(Fixtures.aljoInterviewTurns, [roster[0]]) == [0: "aljo"])
    }

    @Test("Split weights use the duration and confidence on the resolved side")
    func splitWeight() {
        let turns = [SpeakerTurn(videoID: 2, start: 0, end: 10, cluster: 0, confidence: 0.1, resolvedSide: .left),
                     SpeakerTurn(videoID: 2, start: 10, end: 15, cluster: 1, confidence: 1, resolvedSide: .left)]
        #expect(SpeakerClusterNaming.assign(turns: turns, roster: Fixtures.aljoInterviewRoster,
                                             layout: .splitHorizontal, clusterSides: [:], personBySide: [.left: "aljo"])
                == [1: "aljo"])
    }

    @Test("A brief side disagreement does not steal the other side's portrait")
    func splitDisagreement() {
        let turns = [SpeakerTurn(videoID: 2, start: 0, end: 1, cluster: 0, confidence: 1, resolvedSide: .left),
                     SpeakerTurn(videoID: 2, start: 1, end: 11, cluster: 0, confidence: 1, resolvedSide: .right),
                     SpeakerTurn(videoID: 2, start: 11, end: 16, cluster: 1, confidence: 1, resolvedSide: .left)]
        #expect(SpeakerClusterNaming.assign(turns: turns, roster: Fixtures.aljoInterviewRoster,
                                             layout: .splitHorizontal, clusterSides: [:],
                                             personBySide: [.left: "aljo", .right: "ariel"]) == [0: "ariel", 1: "aljo"])
    }

    @Test("Grid naming remains outside the audio cluster rules")
    func grid() {
        #expect(SpeakerClusterNaming.assign(turns: Fixtures.aljoInterviewTurns, roster: Fixtures.aljoInterviewRoster,
                                             layout: .grid, clusterSides: [:], personBySide: [:]).isEmpty)
    }

    private func assign(_ turns: [SpeakerTurn], _ roster: [VideoPersonRecord]) -> [Int: String] {
        SpeakerClusterNaming.assign(turns: turns, roster: roster, layout: .singleCamera,
                                     clusterSides: [:], personBySide: [:])
    }

    @Test("Roster ranges decode and grouped naming summaries follow the active transcript")
    func databaseSummaries() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let emptyVideoID = try await temp.seedVideo()
        let otherVideoID = try await temp.seedVideo()
        try await temp.database.replaceTranscripts(videoID: otherVideoID, transcriptionKey: "other",
            language: "en", isTranslation: false,
            segments: [TranscriptSegment(start: 0, end: 5, text: "Other video", words: nil)],
            provider: "test", model: "test")
        try await temp.database.setActiveTranscriptionKey(videoID: otherVideoID, key: "other")
        try await temp.database.replaceSpeakerTurns(videoID: otherVideoID, transcriptionKey: "other", turns: [
            SpeakerTurn(videoID: otherVideoID, start: 0, end: 5, cluster: 0, confidence: 1),
        ])
        try await temp.database.upsertPerson(key: "aljo", descriptor: "Guest")
        try await temp.database.upsertPerson(key: "ariel", descriptor: "Interviewer")
        let people = try await temp.database.fetchPeople()
        let aljo = try #require(people.first { $0.key == "aljo" })
        let ariel = try #require(people.first { $0.key == "ariel" })
        try await temp.database.replaceVideoPeople(videoID: videoID, entries: [
            (aljo.id, 0, nil, "[{\"start\":0,\"end\":225.06}]"),
            (ariel.id, 213, nil, nil),
        ])
        let roster = try await temp.database.fetchVideoPeople(videoID: videoID)
        #expect(roster.first { $0.key == "aljo" }?.ranges == [0...225.06])
        #expect(roster.first { $0.key == "ariel" }?.ranges == [])
        for key in ["old", "current"] {
            try await temp.database.replaceTranscripts(videoID: videoID, transcriptionKey: key,
                language: "en", isTranslation: false,
                segments: [TranscriptSegment(start: 0, end: 225, text: "Keep this text", words: nil)],
                provider: "test", model: "test")
        }
        try await temp.database.replaceSpeakerTurns(videoID: videoID, transcriptionKey: "old", turns: [
            SpeakerTurn(videoID: videoID, start: 0, end: 10, cluster: 8, confidence: 1, personKey: "removed"),
        ])
        try await temp.database.replaceSpeakerTurns(videoID: videoID, transcriptionKey: "current",
                                                      turns: Fixtures.aljoInterviewTurns)
        try await temp.database.setActiveTranscriptionKey(videoID: videoID, key: "current")
        let summary = try #require(try await temp.database.speakerNamingSummaries()[videoID])
        #expect(summary.clusters == 2)
        #expect(summary.namedClusters == 2)
        #expect(summary.namedKeys == ["aljo"])
        #expect(summary.rosterKeys == ["aljo", "ariel"])
        #expect(summary.verdict.isSuspicious)
        #expect(try await temp.database.speakerNamingSummaries()[emptyVideoID] == nil)
        let other = try #require(try await temp.database.speakerNamingSummaries()[otherVideoID])
        #expect(other.clusters == 1 && other.namedKeys.isEmpty && other.rosterKeys.isEmpty)
        try await temp.database.setActiveTranscriptionKey(videoID: videoID, key: "old")
        let old = try #require(try await temp.database.speakerNamingSummaries()[videoID])
        #expect(old.clusters == 1 && old.namedKeys == ["removed"])
        #expect(old.verdict.isSuspicious)
        #expect(try await temp.database.fetchTranscripts(videoID: videoID).first?.text == "Keep this text")
    }
}
