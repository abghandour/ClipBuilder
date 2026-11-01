import Foundation
import Testing
@testable import Clip_Builder

@Suite("Assistant context")
struct AssistantContextTests {
    private func sample(captions: Bool = false, selection: [String] = ["a.mov"]) -> AssistantContext {
        AssistantContext(page: "AI Wizard", subpage: "Express",
                         facts: [AssistantFact("source", "Source", "a.mov"), AssistantFact("kept", "Kept footage", 2)],
                         settings: [AssistantFact("captions", "Captions", on: captions)],
                         selection: selection, summary: ["Highlights", "Auto", "captions \(captions ? "on" : "off")"])
    }

    @Test func fingerprintIsStableAndContentSensitive() {
        #expect(sample().fingerprint == sample().fingerprint)
        #expect(sample().fingerprint != sample(captions: true).fingerprint)
        #expect(sample().fingerprint != sample(selection: ["b.mov"]).fingerprint)
        // FNV-1a of a fixed string: the same on every launch, unlike Hasher.
        let fixed = AssistantContext.fingerprint(page: "P", subpage: nil, facts: [], settings: [], selection: [])
        #expect(fixed == AssistantContext.fingerprint(page: "P", subpage: nil, facts: [], settings: [], selection: []))
        #expect(!fixed.isEmpty)
    }

    @Test func fingerprintSeparatesFactsFromSettings() {
        let fact = AssistantContext(page: "P", facts: [AssistantFact("k", "K", "v")])
        let setting = AssistantContext(page: "P", settings: [AssistantFact("k", "K", "v")])
        #expect(fact.fingerprint != setting.fingerprint)
    }

    @Test func summaryLineKeepsOrderAndStartsWithSubpage() {
        #expect(sample().summaryLine == "Express · Highlights · Auto · captions off")
        let noSubpage = AssistantContext(page: "Builder", summary: ["Reel", "", "  ", "3 clips"])
        #expect(noSubpage.summaryLine == "Builder · Reel · 3 clips")
        let defaulted = AssistantContext(page: "Reports", facts: [AssistantFact("a", "A", "1"), AssistantFact("b", "B", "2")],
                                         settings: [AssistantFact("c", "C", "3")])
        #expect(defaulted.summaryLine == "Reports · 1 · 2 · 3")
    }

    @Test func lookupsReadFactsThenSettings() {
        let context = sample()
        #expect(context.value("source") == "a.mov")
        #expect(context.int("kept") == 2)
        #expect(context.isOff("captions"))
        #expect(!context.isOn("captions"))
        #expect(context.value("missing") == nil)
        #expect(context.detailText.contains("Source: a.mov"))
        #expect(context.detailText.contains("Captions: off"))
    }

    @Test func selectionIsCapped() {
        let context = AssistantContext(page: "P", selection: (0..<30).map(String.init))
        #expect(context.selection.count == AssistantContext.selectionLimit)
    }

    @Test func pageStateMergesByKey() {
        let base = AssistantPageState(counts: ["a": 1, "b": 2], flags: ["x": true], selection: ["1"])
        let merged = base.merging(AssistantPageState(counts: ["b": 5], values: ["sort": "name"]))
        #expect(merged.counts == ["a": 1, "b": 5])
        #expect(merged.flags == ["x": true])
        #expect(merged.values == ["sort": "name"])
        #expect(merged.selection == ["1"])
        #expect(base.merging(AssistantPageState(selection: ["2"])).selection == ["2"])
    }

    @Test func pageStateCanClearASelection() {
        let selected = AssistantPageState(counts: ["selected": 2], selection: ["a.mov", "b.mov"])
        // Publishing an empty selection clears it; omitting the field keeps it.
        let cleared = selected.merging(AssistantPageState(counts: ["selected": 0], selection: []))
        #expect(cleared.selection == [])
        #expect(cleared.counts["selected"] == 0)
        #expect(selected.merging(AssistantPageState(counts: ["other": 1])).selection == ["a.mov", "b.mov"])
        #expect(AssistantPageState().selection == nil)
    }

    @MainActor
    @Test func clearedSelectionLeavesTheContext() {
        let model = AssistantModel(defaults: UserDefaults(suiteName: "assistant-tests-\(UUID().uuidString)")!)
        model.updatePageState(ScenesAssistant.pageName, AssistantPageState(counts: ["selected": 1], selection: ["a.mov 0:01"]))
        model.updatePageState(ScenesAssistant.pageName, AssistantPageState(counts: ["selected": 0], selection: []))
        #expect(model.state(ScenesAssistant.pageName).selection == [])
    }

    private func row(_ id: String, action: String? = nil, reason: String = "rule") -> AssistantSuggestion {
        AssistantSuggestion(id: id, kind: action == nil ? .insight : .action, title: id, reason: reason, actionID: action)
    }

    @Test func mergeFiltersDismissedAndCaps() {
        let rules = (1...7).map { row("r\($0)") }
        let merged = AssistantModel.merge(rules: rules, ranked: nil, dismissed: [row("r2").dismissKey])
        #expect(merged.map(\.id) == ["r1", "r3", "r4", "r5", "r6"])
        #expect(AssistantModel.merge(rules: rules, ranked: nil, dismissed: [], limit: 2).count == 2)
    }

    @Test func mergePutsRankedFirstAndKeepsRuleActions() {
        let rules = [row("a", action: "act.a"), row("b", action: "act.b"), row("c")]
        let ranked = [row("b", action: "invented", reason: "AI reason"), row("z", action: "nobody")]
        let merged = AssistantModel.merge(rules: rules, ranked: ranked, dismissed: [], offeredActions: ["act.a", "act.b"])
        #expect(merged.map(\.id) == ["b", "a", "c"])
        #expect(merged[0].actionID == "act.b")
        #expect(merged[0].reason == "AI reason")
    }

    @Test func dismissKeyFollowsTheReason() {
        let three = row("builder.flags.review", action: "builder.flags.jump", reason: "unsure about 3 moments")
        let five = row("builder.flags.review", action: "builder.flags.jump", reason: "unsure about 5 moments")
        #expect(three.dismissKey != five.dismissKey)
        #expect(three.dismissKey == row("builder.flags.review", action: "x", reason: "unsure about 3 moments").dismissKey)
        // Dismissed with 3 flags: hidden while the reason is the same, back once it changes.
        #expect(AssistantModel.merge(rules: [three], ranked: nil, dismissed: [three.dismissKey]).isEmpty)
        #expect(AssistantModel.merge(rules: [five], ranked: nil, dismissed: [three.dismissKey]).map(\.id) == ["builder.flags.review"])
        // An AI rephrase alone does not un-hide it: the ranked row keeps the rule's reason key.
        var rephrased = three
        rephrased.reason = "AI: three spots look off"
        rephrased.reasonKey = "AI: three spots look off"
        #expect(AssistantModel.merge(rules: [three], ranked: [rephrased], dismissed: [three.dismissKey]).isEmpty)
        // A ranking cached before the reason changed does not keep the old dismissal.
        #expect(AssistantModel.merge(rules: [five], ranked: [rephrased], dismissed: [three.dismissKey]).map(\.reason)
                == ["AI: three spots look off"])
    }

    @MainActor
    @Test func dismissedPersistsPerProfile() throws {
        let suite = "assistant-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AssistantModel(defaults: defaults)
        let captions = row("express.captions.on", action: "express.set.captions.on", reason: "This source has a transcript")
        model.dismiss(captions, profileName: "One")
        #expect(model.dismissed(profileName: "One") == [captions.dismissKey])
        #expect(model.dismissed(profileName: "Two").isEmpty)
        #expect(AssistantModel(defaults: defaults).dismissed(profileName: "One") == [captions.dismissKey])
        #expect(defaults.stringArray(forKey: AssistantModel.dismissedKey(profileName: "One")) == [captions.dismissKey])
        model.restoreDismissed(profileName: "One")
        #expect(model.dismissed(profileName: "One").isEmpty)
    }

    @MainActor
    @Test func updatePageStateMerges() {
        let model = AssistantModel(defaults: UserDefaults(suiteName: "assistant-tests-\(UUID().uuidString)")!)
        model.updatePageState("Builder", AssistantPageState(counts: ["a": 3]))
        model.updatePageState("Builder", AssistantPageState(counts: ["b": 1]))
        #expect(model.pageState["Builder"]?.counts == ["a": 3, "b": 1])
        model.expressPage = WizardAssistant.ExpressPage()
        model.fullPage = WizardAssistant.FullPage()
        model.reset()
        #expect(model.pageState.isEmpty)
        #expect(model.expressPage == nil)
        #expect(model.fullPage == nil)
    }
}
