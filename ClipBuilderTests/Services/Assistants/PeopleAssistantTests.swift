import Testing
@testable import Clip_Builder

@Suite("People assistant")
struct PeopleAssistantTests {
    private func ids(_ s: PeopleAssistant.Snapshot) -> [String] {
        PeopleAssistant().suggestions(for: PeopleAssistant.context(s)).map(\.id)
    }

    @Test func noPeoplePointsToSources() {
        let rows = PeopleAssistant().suggestions(for: PeopleAssistant.context(.init()))
        #expect(rows.map(\.id) == ["people.none.empty"])
        #expect(rows.first?.actionID == "people.goto.sources")
    }

    @Test func quietWhenEveryoneIsNamedAndResearched() {
        #expect(ids(.init(people: 4, visible: 4, selectedCount: 1)).isEmpty)
    }

    @Test func unnamedPeopleSuggestTheUnknownBucket() {
        let rows = PeopleAssistant().suggestions(for: PeopleAssistant.context(.init(people: 4, visible: 4, unnamed: 2)))
        #expect(rows.map(\.id) == ["people.unnamed"])
        #expect(rows.first?.reason == "2 people still wait on a confirmed name")
        #expect(rows.first?.actionID == "people.unknown")
    }

    @Test func rolelessPeopleSuggestResearch() {
        #expect(ids(.init(people: 4, visible: 4, unresearched: 1)) == ["people.research.missing"])
    }

    @Test func twoSelectedSuggestMerge() {
        #expect(ids(.init(people: 4, visible: 4, selectedCount: 2)) == ["people.merge.selected"])
    }

    @Test func summaryLine() {
        #expect(PeopleAssistant.context(.init(people: 4, unnamed: 1, selectedCount: 1)).summaryLine
                == "People · All People · 4 people · 1 unnamed · 1 selected")
    }

    @Test func routing() {
        #expect(PeopleAssistant.route("Research the people without a role") == "people.research")
        #expect(PeopleAssistant.route("Show me the people who still need a name") == "people.unknown")
        #expect(PeopleAssistant.route("Merge the selected people") == "people.merge")
        #expect(PeopleAssistant.route("make a reel of her") == "people.generate")
        #expect(PeopleAssistant.route("hello") == nil)
    }

    @Test func researchAvailabilityFollowsTheSelection() {
        let fighter = { () -> PersonRecord in
            var person = PersonRecord(id: 1, key: "a", name: "Ana", descriptor: "")
            person.category = .fighter
            return person
        }()
        let unnamed = PersonRecord(id: 2, key: "b", name: "", descriptor: "")
        // A selected named person with a role: the toolbar's Refresh Research is on, so Ask AI's is too.
        let targets = PeopleView.researchTargets(selected: [fighter], visible: [fighter])
        #expect(PeopleAssistant.researchAvailable(targets: targets, inFlight: []))
        // Nothing selected and nobody without a role: off.
        #expect(!PeopleAssistant.researchAvailable(targets: PeopleView.researchTargets(selected: [], visible: [fighter]),
                                                    inFlight: []))
        #expect(!PeopleAssistant.researchAvailable(targets: [unnamed], inFlight: []))
        #expect(!PeopleAssistant.researchAvailable(targets: [fighter], inFlight: [1]))
    }

    @Test func researchActionReadsThePublishedAvailability() {
        // The suggestion count and the action's availability are separate facts.
        let context = PeopleAssistant.context(.init(people: 2, visible: 2, unresearched: 0, canResearch: true, selectedCount: 1))
        #expect(context.isOn("research.available"))
        #expect(context.int("unresearched") == 0)
    }
}
