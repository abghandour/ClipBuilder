import Testing
@testable import Clip_Builder

@Suite("People research targets")
struct PeopleViewResearchTests {
    @Test("An explicit selection is returned unchanged, regardless of category or visibility")
    func selectionWins() {
        let selected = [
            PersonRecord(id: 3, key: "person-3", name: "Zoe", descriptor: "", hidden: true, category: .trainer),
            PersonRecord(id: 2, key: "person-2", name: "", descriptor: "")
        ]
        let visible = [PersonRecord(id: 1, key: "person-1", name: "Ana", descriptor: "")]
        #expect(PeopleView.researchTargets(selected: selected, visible: visible) == selected)
    }

    @Test("Without a selection, only visible named people without a category are returned in order")
    func uncategorizedVisiblePeople() {
        let zoe = PersonRecord(id: 3, key: "person-3", name: "Zoe", descriptor: "")
        let trainer = PersonRecord(id: 2, key: "person-2", name: "Trainer", descriptor: "", category: .trainer)
        let ana = PersonRecord(id: 1, key: "person-1", name: "Ana", descriptor: "")
        #expect(PeopleView.researchTargets(selected: [], visible: [zoe, trainer, ana]) == [zoe, ana])
    }

    @Test("Automatic research excludes empty and whitespace-only names, even with a name-like key")
    func unnamedPeopleExcluded() {
        let unnamed = PersonRecord(id: 1, key: "alex-smith", name: "", descriptor: "")
        let whitespace = PersonRecord(id: 2, key: "person-2", name: " \n\t ", descriptor: "")
        #expect(PeopleView.researchTargets(selected: [], visible: [unnamed, whitespace]).isEmpty)
    }

    @Test("No visible people or only categorized people leaves no automatic research targets")
    func noTargets() {
        let fighter = PersonRecord(id: 1, key: "person-1", name: "Fighter", descriptor: "", category: .fighter)
        #expect(PeopleView.researchTargets(selected: [], visible: []).isEmpty)
        #expect(PeopleView.researchTargets(selected: [], visible: [fighter]).isEmpty)
    }
}
