import Foundation

/// Ask AI on People (PeopleView). The project's people, the Unknown bucket
/// and the research targets are the page's own lists, published as counts.
nonisolated struct PeopleAssistant: PageAssistant {
    static let pageName = "People"
    let page = Self.pageName
    let examples = ["Research the people without a role",
                    "Show me the people who still need a name",
                    "Merge the selected people"]

    struct Snapshot: Equatable, Sendable {
        var people = 0
        var visible = 0
        var hidden = 0
        /// Waiting on a confirmed name (the Unknown bucket).
        var unnamed = 0
        /// Named, visible, no role yet: what Refresh Research proposes roles for
        /// with nothing selected (the suggestion's count).
        var unresearched = 0
        /// The toolbar's Refresh Research is enabled: the selection when
        /// there is one, else the people without a role (`researchAvailable`).
        var canResearch = false
        var selectedCount = 0
        var selected: [String] = []
        /// Scenes shown for the selected person (Generate Video's source).
        var personScenes = 0
        var bucket = "All People"
    }

    static func context(_ s: Snapshot) -> AssistantContext {
        let facts = [
            AssistantFact("people", "People", s.people),
            AssistantFact("visible", "Visible", s.visible),
            AssistantFact("hidden", "Hidden", s.hidden),
            AssistantFact("unnamed", "Waiting on a name", s.unnamed),
            AssistantFact("unresearched", "Named without a role", s.unresearched),
            AssistantFact("research.available", "Refresh Research available", on: s.canResearch),
            AssistantFact("selected", "Selected", s.selectedCount),
            AssistantFact("personScenes", "Scenes of the selected person", s.personScenes),
        ]
        var summary = [s.bucket, AssistantText.count(s.people, "person", "people")]
        if s.unnamed > 0 { summary.append("\(s.unnamed) unnamed") }
        if s.selectedCount > 0 { summary.append("\(s.selectedCount) selected") }
        return AssistantContext(page: pageName, facts: facts, settings: [AssistantFact("bucket", "Showing", s.bucket)],
                                selection: s.selectedCount > 0 ? s.selected : [], summary: summary)
    }

    @MainActor
    func snapshot(store: AppStore) -> Snapshot {
        let state = store.assistant.state(page)
        return Snapshot(people: state.counts["people"] ?? store.people.count, visible: state.count("visible"),
                        hidden: state.count("hidden"), unnamed: state.count("unnamed"),
                        unresearched: state.count("unresearched"), canResearch: state.flag("research.available"),
                        selectedCount: state.count("selected"),
                        selected: state.selection ?? [], personScenes: state.count("personScenes"),
                        bucket: state.text("bucket") ?? "All People")
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext { Self.context(snapshot(store: store)) }

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        guard (context.int("people") ?? 0) > 0 else {
            return [.init(id: "people.none.empty", kind: .action, title: "Analyze a source",
                          reason: "No people yet: analysis detects who is on screen", actionID: "people.goto.sources")]
        }
        var rows: [AssistantSuggestion] = []
        let unnamed = context.int("unnamed") ?? 0
        if unnamed > 0 {
            rows.append(.init(id: "people.unnamed", kind: .action, title: "Name the unknown people",
                              reason: "\(AssistantText.count(unnamed, "person", "people")) still \(unnamed == 1 ? "waits" : "wait") on a confirmed name",
                              actionID: "people.unknown"))
        }
        let unresearched = context.int("unresearched") ?? 0
        if unresearched > 0 {
            rows.append(.init(id: "people.research.missing", kind: .action, title: "Refresh research",
                              reason: "\(AssistantText.count(unresearched, "named person", "named people")) \(unresearched == 1 ? "has" : "have") no role yet",
                              actionID: "people.research"))
        }
        if (context.int("selected") ?? 0) >= 2 {
            rows.append(.init(id: "people.merge.selected", kind: .action, title: "Merge the selected people",
                              reason: "\(context.int("selected") ?? 0) people selected: merge them if they are the same person",
                              actionID: "people.merge"))
        }
        return rows
    }

    /// The toolbar's Refresh Research enabled state for `targets`
    /// (PeopleView.researchTargets: the selection, else everyone visible
    /// without a role): someone named, and not everyone already in flight.
    static func researchAvailable(targets: [PersonRecord], inFlight: Set<Int64>) -> Bool {
        targets.contains { !$0.isUnnamed && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && !targets.allSatisfy { inFlight.contains($0.id) }
    }

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        let page = page
        func count(_ key: String, atLeast n: Int) -> @MainActor @Sendable (AppStore) -> Bool {
            { $0.assistant.state(page).count(key) >= n }
        }
        return [
            .command("people.research", "Refresh Research", "arrow.clockwise.circle", message: "Researching people.",
                     available: { $0.assistant.state(page).flag("research.available") }),
            .command("people.unknown", "Show Unknown", "person.fill.questionmark", message: "Showing the people waiting on a name."),
            .command("people.merge", "Merge People", "person.2.crop.square.stack", message: "Opened Merge.",
                     available: count("selected", atLeast: 2)),
            .command("people.generate", "Generate Video", "wand.and.stars", message: "Opened Generate Video.",
                     available: count("personScenes", atLeast: 1)),
            .open("people.goto.sources", .sources, title: "Open Sources"),
        ]
    }

    static func route(_ text: String) -> String? {
        let t = AssistantText.normalized(text)
        if t.isEmpty { return nil }
        if AssistantText.mentions(t, ["merge", "same person", "duplicate"]) { return "people.merge" }
        if AssistantText.mentions(t, ["research", "role", "look up", "who is"]) { return "people.research" }
        if AssistantText.mentions(t, ["unknown", "unnamed", "need a name", "needs a name", "name"]) { return "people.unknown" }
        if AssistantText.mentions(t, ["generate", "video", "reel"]) { return "people.generate" }
        return nil
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        AssistantText.run(Self.route(text), actions: actions(store: store), store: store,
                          fallback: AssistantText.unrecognized(page: page, examples: examples))
    }
}
