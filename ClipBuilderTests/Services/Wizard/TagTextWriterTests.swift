import Foundation
import Testing
@testable import Clip_Builder

@Suite("Tag text writer")
struct TagTextWriterTests {
    @Test func promptBatchesPeopleAndNamesTheField() {
        let people = [TagTextWriter.Person(key: "ann", name: "Ann", category: "Press", transcript: "I report on fights."),
                      TagTextWriter.Person(key: "bob", name: "Bob", category: "Fighter", transcript: "I train daily.")]
        let prompt = TagTextWriter.prompt(field: "Profession", people: people)
        #expect(prompt.contains("Profession") && prompt.contains("ann") && prompt.contains("bob"))
        #expect(prompt.contains("I report on fights.") && prompt.contains("Fighter"))
        #expect(TagTextWriter.fieldKey("  ") == "Role")
    }

    @Test func parsingIgnoresUnknownKeysAndInvalidValuesAndBoundsText() {
        let people = ["ann", "bob", "cam", "dan"].map {
            TagTextWriter.Person(key: $0, name: $0.capitalized, category: "", transcript: "")
        }
        let response = """
        ```json
        {"ann":"  Sports\\njournalist  ","bob":"BOB", "cam":"", "dan":"\(String(repeating: "é", count: 60))", "unknown":"Intruder"}
        ```
        """
        let parsed = TagTextWriter.parse(response, people: people)
        #expect(parsed["ann"] == "Sports journalist")
        #expect(parsed["bob"] == nil && parsed["cam"] == nil && parsed["unknown"] == nil)
        #expect(parsed["dan"]?.count == 40)
        #expect(TagTextWriter.parse("broken", people: people).isEmpty)
        #expect(TagTextWriter.parse(#"{"ann":123}"#, people: people).isEmpty)
    }

    @Test func excerptUsesOnlyThisPersonsSpeechInsideTheCut() {
        func row(_ id: Int64, _ text: String, _ speaker: String?, start: Double) -> TranscriptRow {
            TranscriptRow(id: id, videoID: 1, language: "en", isTranslation: false,
                startTime: start, endTime: start + 1, text: text, speakerKey: speaker)
        }
        let rows = [row(1, "Ann's line", "ann", start: 1), row(2, "Bob's line", "bob", start: 2),
                    row(3, "Automatic Ann", nil, start: 3), row(4, "Unknown", "", start: 4),
                    row(5, "Outside", "ann", start: 20)]
        let turns = [SpeakerTurn(videoID: 1, start: 3, end: 5, cluster: 0, confidence: 1, personKey: "ann")]
        #expect(TagTextWriter.excerpt(personKey: "ann", rows: rows, turns: turns, ranges: [0...10]) == "Ann's line Automatic Ann")
    }
}
