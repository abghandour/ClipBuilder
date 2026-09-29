import Foundation
import Testing
@testable import Clip_Builder

@Suite("People Roles inference")
struct PersonRoleInferenceTests {
    @Test("proposals follow the asked order, drop unknown roles and strangers, and clamp confidence")
    func parse() {
        let response = """
        Here you go:
        {"people": [
          {"id": 3, "category": "Press", "confidence": 0.9, "reason": "Hosts the podcast."},
          {"id": 1, "category": "fighter", "confidence": 1.7, "reason": "Fights in IMG_3741."},
          {"id": 1, "category": "fan", "confidence": 0.2, "reason": "duplicate answer"},
          {"id": 9, "category": "fighter", "confidence": 0.5, "reason": "not asked about"},
          {"id": "2", "category": "astronaut", "confidence": 0.5, "reason": "unknown role"}
        ]}
        """
        let proposals = PersonRoleInference.parse(response, personIDs: [1, 2, 3])
        #expect(proposals.map(\.personID) == [1, 3])
        #expect(proposals[0].category == .fighter)
        #expect(proposals[0].confidence == 1)
        #expect(proposals[1].category == .press)
        #expect(proposals[1].reason == "Hosts the podcast.")
        #expect(PersonRoleInference.parse("no json here", personIDs: [1]).isEmpty)
    }

    @Test("quotes come from lines attributed by hand or by an overlapping speaker turn, never translations")
    func quotes() {
        func row(_ id: Int64, _ start: Double, _ end: Double, _ text: String,
                 speaker: String? = nil, translation: Bool = false) -> TranscriptRow {
            TranscriptRow(id: id, videoID: 1, language: "en", isTranslation: translation, startTime: start,
                          endTime: end, text: text, originalText: nil, wordsJSON: nil, provider: nil,
                          model: nil, speakerKey: speaker)
        }
        let rows = [
            row(1, 0, 4, "I have trained for this fight my whole life"),          // turn says alpha
            row(2, 4, 8, "And how did the camp go for you", speaker: "beta"),     // attributed to beta
            row(3, 8, 12, "Camp was great, my coach pushed me hard", speaker: "alpha"),
            row(4, 12, 16, "Short"),                                             // too short
            row(5, 16, 20, "J'ai entraîné toute ma vie pour ce combat", translation: true),
            row(6, 20, 24, "Nobody knows who said this one", speaker: ""),       // Unknown
        ]
        let turns = [
            SpeakerTurn(videoID: 1, start: 0, end: 5, cluster: 0, confidence: 1, personKey: "alpha"),
            SpeakerTurn(videoID: 1, start: 5, end: 30, cluster: 1, confidence: 1, personKey: "beta"),
        ]
        let alpha = PersonRoleInference.quotes(for: "alpha", transcripts: rows, turns: turns)
        #expect(alpha == ["I have trained for this fight my whole life", "Camp was great, my coach pushed me hard"])
        let beta = PersonRoleInference.quotes(for: "beta", transcripts: rows, turns: turns)
        #expect(beta == ["And how did the camp go for you"])
    }

    @Test("the prompt lists every role and each person's evidence")
    func prompt() {
        let dossier = PersonRoleInference.Dossier(
            personID: 7, name: "Marcello Spinelli", descriptor: "shaved head, black rashguard",
            videos: ["Podcast 01.mp4 (Podcast)"], scenes: ["Podcast 01.mp4: [talking, studio]"],
            quotes: ["I fought in Rio last year"])
        let prompt = PersonRoleInference.prompt(dossiers: [dossier], domain: "MMA")
        for category in PersonCategory.allCases {
            #expect(prompt.contains("- \(category.rawValue): "), Comment(rawValue: category.rawValue))
        }
        #expect(prompt.contains("### PERSON 7: Marcello Spinelli"))
        #expect(prompt.contains("Podcast 01.mp4 (Podcast)"))
        #expect(prompt.contains("\"I fought in Rio last year\""))
    }
}
