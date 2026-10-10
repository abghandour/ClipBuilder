import Foundation
import Testing
@testable import Clip_Builder

@Suite("Tag text writer")
struct TagTextWriterTests {
    @Test func normalizeHandlesAndProfileURLs() {
        #expect(TagTextWriter.profileFields == ["Role", "Profession", "MMA record", "Team", "Nationality", "Instagram", "X"])
        for field in ["Instagram", "X"] {
            #expect(TagTextWriter.normalizeHandle("@name", field: field) == "name")
            #expect(TagTextWriter.normalizeHandle(" \n @Name_1 \t", field: field) == "Name_1")
            #expect(TagTextWriter.normalizeHandle("", field: field) == nil)
            #expect(TagTextWriter.normalizeHandle("@", field: field) == nil)
            #expect(TagTextWriter.normalizeHandle("first last", field: field) == nil)
            #expect(TagTextWriter.normalizeHandle("first\nlast", field: field) == nil)
            #expect(TagTextWriter.normalizeHandle("na-me", field: field) == nil)
            #expect(TagTextWriter.normalizeHandle("namé", field: field) == nil)
        }
        #expect(TagTextWriter.normalizeHandle("https://www.instagram.com/name/?hl=en", field: "Instagram") == "name")
        #expect(TagTextWriter.normalizeHandle("http://www.instagram.com/Name.1///?hl=en", field: "Instagram") == "Name.1")
        #expect(TagTextWriter.normalizeHandle("x.com/name", field: "X") == "name")
        #expect(TagTextWriter.normalizeHandle("twitter.com/name", field: "X") == "name")
        #expect(TagTextWriter.normalizeHandle("https://www.twitter.com/name/?lang=en", field: "X") == "name")
        #expect(TagTextWriter.normalizeHandle("https://instagram.com/?hl=en", field: "Instagram") == nil)
        #expect(TagTextWriter.normalizeHandle("name.1", field: "X") == nil)
        #expect(TagTextWriter.normalizeHandle("name/path", field: "Instagram") == nil)
        for (field, limit) in [("Instagram", 30), ("X", 15)] {
            let handle = String(repeating: "a", count: limit)
            #expect(TagTextWriter.normalizeHandle(handle, field: field) == handle)
            #expect(TagTextWriter.normalizeHandle(handle + "a", field: field) == nil)
        }
    }

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
