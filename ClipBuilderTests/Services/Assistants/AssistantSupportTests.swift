import Testing
@testable import Clip_Builder

@Suite("Assistant support")
struct AssistantSupportTests {
    @Test func mentionsIsCaseInsensitive() {
        #expect(AssistantText.mentions("  Publish THE newest ", ["publish"]))
        #expect(!AssistantText.mentions("open it", ["publish"]))
    }

    @Test func remainderTakesWordsAfterTheFirstMarker() {
        #expect(AssistantText.remainder(of: "Find scenes about the Knockout!", after: ["about "]) == "the Knockout")
        #expect(AssistantText.remainder(of: "find scenes with Jon", after: ["about ", "with "]) == "Jon")
        #expect(AssistantText.remainder(of: "find the walkout", after: ["about ", "find "]) == "the walkout")
        #expect(AssistantText.remainder(of: "search for scenes of the crowd", after: ["search for "]) == "of the crowd")
        #expect(AssistantText.remainder(of: "find", after: ["find "]) == nil)
        #expect(AssistantText.remainder(of: "find about", after: ["about "]) == nil)
    }

    @Test func countPluralizes() {
        #expect(AssistantText.count(1, "source") == "1 source")
        #expect(AssistantText.count(3, "source") == "3 sources")
        #expect(AssistantText.count(2, "person", "people") == "2 people")
    }

    @Test func emptyPublishedTextReadsAsAbsent() {
        let state = AssistantPageState(values: ["a": "", "b": "x"])
        #expect(state.text("a") == nil)
        #expect(state.text("b") == "x")
        #expect(state.value("a") == "")
        #expect(state.count("missing") == 0)
        #expect(!state.flag("missing"))
    }

    @Test func unrecognizedNamesThePageAndAnExample() {
        guard case .unavailable(let message) = AssistantText.unrecognized(page: "Scenes", examples: ["Find X"]) else {
            Issue.record("expected unavailable"); return
        }
        #expect(message.contains("Scenes"))
        #expect(message.contains("Find X"))
    }
}
