import Testing
@testable import Clip_Builder

@Suite("Person display names")
struct PersonRecordTests {
    @Test("an unconfirmed person is called what the analyzer read into the key; generic keys stay unnamed")
    func displayName() {
        let read = PersonRecord(id: 1, key: "marcello-spinelli", name: "", descriptor: "")
        #expect(read.displayName == "Marcello Spinelli")
        #expect(read.keyName == "Marcello Spinelli")
        #expect(read.isUnnamed)

        let confirmed = PersonRecord(id: 1, key: "marcello-spinelli", name: "Marcelo Spinelli", descriptor: "")
        #expect(confirmed.displayName == "Marcelo Spinelli")
        #expect(!confirmed.isUnnamed)

        for key in ["person-2", "speaker-1", "unknown", "guest-3", "3"] {
            #expect(PersonRecord.keyName(key) == nil, "\(key)")
            #expect(PersonRecord(id: 1, key: key, name: "", descriptor: "").displayName == "Unnamed person")
        }
        #expect(PersonRecord.keyName("jack-della-maddalena") == "Jack Della Maddalena")
    }

    @Test("a name tag uses the confirmed name, else the name read into the key, never a counter key")
    func tagName() {
        #expect(PersonRecord(id: 1, key: "tanner-boser", name: "", descriptor: "").tagName == "Tanner Boser")
        #expect(PersonRecord(id: 1, key: "tanner-boser", name: "Tanner B.", descriptor: "").tagName == "Tanner B.")
        for key in ["person-2", "speaker-1", "fighter-1-primary", "octagon-fighter-2", "3"] {
            #expect(PersonRecord(id: 1, key: key, name: "", descriptor: "").tagName == nil, "\(key)")
        }
        #expect(PersonRecord(id: 1, key: "fighter-1-primary", name: "Carlos Prates", descriptor: "").tagName == "Carlos Prates")
    }
}
