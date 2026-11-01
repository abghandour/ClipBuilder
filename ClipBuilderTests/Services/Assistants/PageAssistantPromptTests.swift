import Foundation
import Testing
@testable import Clip_Builder

@Suite("Page assistant prompt")
struct PageAssistantPromptTests {
    private let context = AssistantContext(page: "AI Wizard", subpage: "Express",
                                           facts: [AssistantFact("source", "Source", "fight.mov")],
                                           settings: [AssistantFact("captions", "Captions", on: false)],
                                           selection: ["fight.mov"], summary: ["Highlights", "Auto"])
    private let actions = [PageAssistantPrompt.Action(id: "wizard.generate", title: "Generate"),
                           PageAssistantPrompt.Action(id: "express.set.captions.on", title: "Turn on captions")]
    private let rules = [AssistantSuggestion(id: "express.captions.on", kind: .setting, title: "Turn on captions",
                                             reason: "This source has a transcript", actionID: "express.set.captions.on"),
                         AssistantSuggestion(id: "wizard.analyze.first", kind: .insight, title: "Analyze first",
                                             reason: "No scenes")]
    private let settings = [AssistantSetting("length", "Length", .choice(["10", "15", "30", "auto"]),
                                             choiceLabels: ["30": "30 s", "auto": "Auto"]),
                            AssistantSetting("captions", "Captions", .bool),
                            AssistantSetting("aiInstructions", "AI instructions", .text(maxLength: 10))]

    private typealias S = PageAssistantPrompt.Section

    /// The lines under `header`, up to the next section.
    private func section(_ header: String, in prompt: String) -> [String] {
        guard let start = prompt.range(of: header) else { return [] }
        let rest = prompt[start.upperBound...]
        let body = rest.range(of: "\n## ").map { rest[..<$0.lowerBound] } ?? rest
        // The first piece is the rest of the header line (a suffix or empty).
        return body.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
            .map(String.init).filter { !$0.isEmpty }
    }

    @Test func rankingPromptHasItsSectionsInOrder() {
        let prompt = PageAssistantPrompt.build(context: context, actions: actions, settings: settings, question: nil,
                                               suggestions: rules)
        let order = [S.page, S.facts, S.settings, S.selection, S.actions, S.suggestions, S.task, S.answer]
        let positions = order.compactMap { prompt.range(of: $0)?.lowerBound }
        #expect(positions.count == order.count)
        #expect(positions == positions.sorted())
        #expect(!prompt.contains(S.request))
        #expect(!prompt.contains(S.changeable))
        #expect(prompt.contains(#""suggestions""#))
        #expect(section(S.suggestions, in: prompt) == ["- express.captions.on: Turn on captions — This source has a transcript",
                                                       "- wizard.analyze.first: Analyze first — No scenes"])
        #expect(prompt.contains("Summary: Express · Highlights · Auto"))
        #expect(section(S.facts, in: prompt) == ["- source (Source): fight.mov"])
    }

    @Test func understandingPromptHasTheRequestAndTheWhitelist() {
        let prompt = PageAssistantPrompt.build(context: context, actions: actions, settings: settings,
                                               question: "  make it 30 seconds\n")
        let order = [S.page, S.facts, S.settings, S.selection, S.actions, S.changeable, S.request, S.task, S.answer]
        let positions = order.compactMap { prompt.range(of: $0)?.lowerBound }
        #expect(positions.count == order.count)
        #expect(positions == positions.sorted())
        #expect(!prompt.contains(S.suggestions))
        #expect(section(S.request, in: prompt) == ["make it 30 seconds"])
        #expect(section(S.changeable, in: prompt) == [
            "- length (Length): one of: 10, 15, 30 (30 s), auto (Auto)",
            "- captions (Captions): true or false",
            "- aiInstructions (AI instructions): text, at most 10 characters (\"\" clears it)",
        ])
        #expect(prompt.contains(#"{"action": "<action id>" or null"#))
    }

    @Test func onlyCatalogueIdsAreOffered() {
        let prompt = PageAssistantPrompt.build(context: context, actions: actions, settings: [], question: "x")
        #expect(section(S.actions, in: prompt) == ["- wizard.generate: Generate", "- express.set.captions.on: Turn on captions"])
        let empty = PageAssistantPrompt.build(context: context, actions: [], settings: [], question: nil)
        #expect(section(S.actions, in: empty) == ["(none)"])
        #expect(section(S.suggestions, in: empty) == ["(none)"])
    }

    // MARK: - Ranking replies

    @Test func rankingKeepsKnownIdsInOrderAndDropsTheRest() {
        let reply = """
        ```json
        {"suggestions": [
          {"id": "wizard.analyze.first", "reason": "  Nothing is analyzed\\nyet  "},
          {"id": "made.up.id", "reason": "invented"},
          "express.captions.on",
          {"id": "wizard.analyze.first"},
          {"id": "wizard.generate", "reason": "Kept footage is ready"},
          42
        ]}
        ```
        """
        let ranked = PageAssistantPrompt.parseRanking(reply, suggestions: rules, actions: actions)
        #expect(ranked == [.init(id: "wizard.analyze.first", reason: "Nothing is analyzed yet"),
                           .init(id: "express.captions.on", reason: nil),
                           .init(id: "wizard.generate", reason: "Kept footage is ready")])
    }

    @Test func rankingIsCappedAndReasonsBounded() {
        let many = (0..<8).map { AssistantSuggestion(id: "r\($0)", kind: .action, title: "R", reason: "x") }
        let items = many.map { #"{"id": "\#($0.id)", "reason": "\#(String(repeating: "a", count: 400))"}"# }
        let ranked = PageAssistantPrompt.parseRanking(#"{"suggestions": [\#(items.joined(separator: ","))]}"#,
                                                      suggestions: many, actions: []) ?? []
        #expect(ranked.count == PageAssistantPrompt.rankingLimit)
        #expect(ranked.allSatisfy { ($0.reason?.count ?? 0) == PageAssistantPrompt.reasonLimit })
    }

    @Test func badRankingJSONIsNil() {
        #expect(PageAssistantPrompt.parseRanking("I think captions matter most.", suggestions: rules, actions: actions) == nil)
        #expect(PageAssistantPrompt.parseRanking(#"{"ranking": []}"#, suggestions: rules, actions: actions) == nil)
        #expect(PageAssistantPrompt.parseRanking(#"{"suggestions": "express.captions.on"}"#, suggestions: rules, actions: actions) == nil)
        #expect(PageAssistantPrompt.parseRanking(#"{"suggestions": []}"#, suggestions: rules, actions: actions) == [])
    }

    // MARK: - Answers

    private func answer(_ raw: String) -> PageAssistantPrompt.Parsed {
        PageAssistantPrompt.parseAnswer(raw, actions: actions, settings: settings)
    }

    @Test func answerWithActionAndSettings() {
        #expect(answer(#"{"action": "wizard.generate", "settings": {"length": 30, "captions": true}, "reply": "Set 30 s.\n"}"#)
                == .answer(.init(actionID: "wizard.generate", settings: ["length": "30", "captions": "true"], reply: "Set 30 s.")))
        #expect(answer(#"{"action": null, "settings": {"length": "Auto", "aiInstructions": "  funnier please, much funnier "}, "reply": ""}"#)
                == .answer(.init(actionID: nil, settings: ["length": "auto", "aiInstructions": "funnier pl"], reply: "")))
        #expect(answer(#"{"action": "", "settings": {"captions": "on"}}"#)
                == .answer(.init(actionID: nil, settings: ["captions": "true"], reply: "")))
    }

    @Test func unknownActionOrKeyIsRefused() {
        #expect(answer(#"{"action": "wizard.delete.everything", "settings": {}, "reply": "Done"}"#)
                == .refused("Ask AI picked an action this page does not offer."))
        #expect(answer(#"{"action": null, "settings": {"quality": "best"}, "reply": "Done"}"#)
                == .refused("Ask AI cannot change “quality” on this page."))
        #expect(answer(#"{"action": null, "settings": {"length": 45}, "reply": "Done"}"#)
                == .refused("That is not a valid value for Length."))
        #expect(answer(#"{"action": null, "settings": {"captions": "maybe"}}"#)
                == .refused("That is not a valid value for Captions."))
    }

    @Test func nothingToDoIsRefusedWithTheReply() {
        #expect(answer(#"{"action": null, "settings": {}, "reply": "This page cannot publish."}"#)
                == .refused("This page cannot publish."))
        #expect(answer(#"{"action": null}"#) == .refused("Ask AI could not match that to anything on this page."))
    }

    @Test func badAnswerJSONIsUnreadable() {
        #expect(answer("Sure! I set the length to 30 seconds.") == .unreadable)
        #expect(answer(#"{"action": 3}"#) == .unreadable)
        #expect(answer(#"{"action": null, "settings": ["length"]}"#) == .unreadable)
    }
}

@Suite("Assistant settings whitelist")
struct AssistantSettingTests {
    @Test func boolsAcceptJSONBooleansAndWords() {
        let setting = AssistantSetting("x", "X", .bool)
        #expect(setting.normalize(true) == "true")
        #expect(setting.normalize(NSNumber(value: false)) == "false")
        #expect(setting.normalize("Yes") == "true")
        #expect(setting.normalize("off") == "false")
        #expect(setting.normalize(1) == "true")
        #expect(setting.normalize(2) == nil)
        #expect(setting.normalize("sometimes") == nil)
    }

    @Test func integersStayInRange() {
        let setting = AssistantSetting("s", "Seconds", .integer(5...600))
        #expect(setting.normalize(30) == "30")
        #expect(setting.normalize(29.6) == "30")
        #expect(setting.normalize("45 seconds") == "45")
        #expect(setting.normalize(2) == nil)
        #expect(setting.normalize(true) == nil)
        #expect(setting.normalize("long") == nil)
    }

    @Test func choicesMatchValuesThenLabels() {
        let setting = AssistantSetting("folder", "Folder", .choice(["all", "source:a.mov"]),
                                       choiceLabels: ["all": "All", "source:a.mov": "a.mov"])
        #expect(setting.normalize("ALL") == "all")
        #expect(setting.normalize("a.mov") == "source:a.mov")
        #expect(setting.normalize("b.mov") == nil)
        #expect(setting.normalize(false) == nil)
    }

    @Test func wizardSettingsRequestsAreTold() {
        for text in ["make it 30 seconds", "Turn on captions", "no watermark", "captions off please", "set length to 15"] {
            #expect(WizardAssistant.isSettingsRequest(text), Comment(rawValue: text))
        }
        for text in WizardAssistant().examples + ["", "a reel", "Make a 30-second reel of the funniest moments"] {
            #expect(!WizardAssistant.isSettingsRequest(text), Comment(rawValue: text))
        }
    }

    @Test func expressWhitelistIsThePlansKeys() {
        #expect(WizardAssistant.expressSettings.map(\.key)
                == ["length", "captions", "nameTags", "safeAreaOnly", "watermark", "transition", "aiInstructions"])
        #expect(WizardAssistant.fullSettings.map(\.key)
                == ["targetDurationSeconds", "addCaptions", "includeHeadline", "formatPreset", "aiInstructions"])
        #expect(ScenesAssistant.settings(tags: ["fight"]).map(\.key) == ["favoritesOnly", "tagFilter", "searchText", "sortByScore"])
        #expect(ExportsAssistant.settings(folders: []).map(\.key) == ["selectedFolder"])
    }

    @Test func expressPatchWritesTheFormState() {
        var settings = MiniWizardSettings()
        var length = MiniWizardFlow.Length.automatic
        var instructions: String?
        WizardAssistant.applyExpress(["length": "30", "captions": "true", "watermark": "false", "transition": "fade",
                                      "aiInstructions": "funnier", "quality": "best"],
                                     settings: &settings, length: &length, instructions: &instructions)
        #expect(length == .thirty)
        #expect(settings.captions)
        #expect(!settings.watermark)
        #expect(settings.transition == "fade")
        #expect(instructions == "funnier")
    }

    @Test func fullPatchWritesTheWizardDefaults() throws {
        let suite = "PageAssistantPromptTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(WizardTextMode.headlines.rawValue, forKey: WizardDefaults.textModeKey)
        WizardAssistant.applyFull(["targetDurationSeconds": "30", "addCaptions": "true", "includeHeadline": "false",
                                   "formatPreset": "custom", "aiInstructions": "only the knockout"], defaults: defaults)
        #expect(defaults.string(forKey: WizardDefaults.durationModeKey) == WizardDurationMode.custom.rawValue)
        #expect(defaults.integer(forKey: WizardDefaults.customDurationKey) == 30)
        #expect(defaults.string(forKey: WizardDefaults.textModeKey) == WizardTextMode.both.rawValue)
        #expect(defaults.string(forKey: WizardDefaults.brandingOverrideKey) == WizardBrandingOverride.minimal.rawValue)
        #expect(defaults.string(forKey: "wizard.formatPreset") == "custom")
        #expect(defaults.string(forKey: "wizard.aiInstructions") == "only the knockout")
        WizardAssistant.applyFull(["addCaptions": "false"], defaults: defaults)
        #expect(defaults.string(forKey: WizardDefaults.textModeKey) == WizardTextMode.headlines.rawValue)
    }

    @Test func exportsFoldersRoundTrip() {
        let folders = [("all", "All"), ("source:a.mov", "a.mov")]
        let decoded = ExportsAssistant.decodeFolders(ExportsAssistant.encodeFolders(folders.map { (id: $0.0, title: $0.1) }))
        #expect(decoded.map(\.id) == ["all", "source:a.mov"])
        #expect(decoded.map(\.title) == ["All", "a.mov"])
        #expect(ExportsAssistant.decodeFolders(nil).isEmpty)
    }

    @Test func scenesTagsAreOrderedByUse() {
        #expect(ScenesAssistant.tagsByUse([["b", "a"], ["a"], ["c", "a", "a"]]) == ["a", "b", "c"])
    }
}
