import Testing
@testable import Clip_Builder

@Suite("Person picker filtering")
struct PersonPickerTests {
    @Test("empty and whitespace-only queries preserve the caller's order")
    func emptyQuery() {
        let people = [
            PersonRecord(id: 2, key: "person-2", name: "Zoe", descriptor: ""),
            PersonRecord(id: 1, key: "person-1", name: "Ana", descriptor: "")
        ]
        #expect(PersonPickerPopover.filtered(people, query: "") == people)
        #expect(PersonPickerPopover.filtered(people, query: " \n\t ") == people)
    }

    @Test("names match regardless of case, diacritics, or surrounding query whitespace")
    func foldedNames() {
        let carlos = PersonRecord(id: 1, key: "person-1", name: "Carlos Prates", descriptor: "")
        let jose = PersonRecord(id: 2, key: "person-2", name: "José", descriptor: "")
        let people = [carlos, jose]
        #expect(PersonPickerPopover.filtered(people, query: "prates") == [carlos])
        #expect(PersonPickerPopover.filtered(people, query: " PRATES \n") == [carlos])
        #expect(PersonPickerPopover.filtered(people, query: "jose") == [jose])
        #expect(PersonPickerPopover.filtered(people, query: "JOSÉ") == [jose])
    }

    @Test("prefix matches lead while each group retains the caller's order")
    func prefixOrder() {
        let substring = PersonRecord(id: 1, key: "person-1", name: "Maria José", descriptor: "")
        let prefix = PersonRecord(id: 2, key: "person-2", name: "José Silva", descriptor: "")
        let otherSubstring = PersonRecord(id: 3, key: "person-3", name: "Ana Josefina", descriptor: "")
        let otherPrefix = PersonRecord(id: 4, key: "person-4", name: "Josefina", descriptor: "")
        let people = [substring, prefix, otherSubstring, otherPrefix]
        #expect(PersonPickerPopover.filtered(people, query: "jose")
                == [prefix, otherPrefix, substring, otherSubstring])
    }

    @Test("a query with no matching name returns no people")
    func noMatch() {
        let person = PersonRecord(id: 1, key: "person-1", name: "Carlos Prates", descriptor: "José")
        #expect(PersonPickerPopover.filtered([person], query: "jose").isEmpty)
        #expect(PersonPickerPopover.filtered([], query: "jose").isEmpty)
    }

    @Test("the name read from a key matches even when a different name is confirmed")
    func keyName() {
        let person = PersonRecord(id: 1, key: "josé-silva", name: "Joe", descriptor: "")
        let substring = PersonRecord(id: 2, key: "person-2", name: "Maria José", descriptor: "")
        #expect(PersonPickerPopover.filtered([substring, person], query: "jose") == [person, substring])
        #expect(PersonPickerPopover.filtered([person], query: "SILVA") == [person])
    }

    @Test("unnamed people can be found by their displayed fallback name")
    func unnamedDisplayName() {
        let person = PersonRecord(id: 1, key: "person-1", name: "", descriptor: "")
        #expect(PersonPickerPopover.filtered([person], query: "unnamed") == [person])
    }
}
