import Foundation

/// Ask AI on Timelines (TimelinesView). Everything it reads is on the store;
/// rendering happens in the Builder, so "render" suggestions open the
/// timeline there, the way the row's Open does.
nonisolated struct TimelinesAssistant: PageAssistant {
    static let pageName = "Timelines"
    let page = Self.pageName
    let examples = ["Open the newest timeline",
                    "Start a new timeline from the Wizard",
                    "Create an empty timeline"]

    struct Snapshot: Equatable, Sendable {
        var count = 0
        var builders = 0
        var wizards = 0
        var newest: String?
        /// Timelines edited after the project's newest export.
        var changedSinceExport = 0
        var newestChanged: String?
        /// Timelines never opened in the Builder.
        var neverOpened = 0
        var newestNeverOpened: String?
    }

    /// SQLite timestamps ("yyyy-MM-dd HH:mm:ss") order as strings.
    static func edited(_ timeline: TimelineRecord) -> String { timeline.editedAt ?? timeline.createdAt ?? "" }

    /// Newest first.
    static func byEdit(_ timelines: [TimelineRecord]) -> [TimelineRecord] {
        timelines.sorted { edited($0) > edited($1) }
    }

    /// Timelines changed after `lastExport` (nil: no export yet, so every
    /// Builder timeline counts).
    static func changed(_ timelines: [TimelineRecord], lastExport: String?) -> [TimelineRecord] {
        byEdit(timelines).filter { !$0.isWizard && edited($0) > (lastExport ?? "") }
    }

    static func context(_ s: Snapshot) -> AssistantContext {
        var facts = [
            AssistantFact("timelines", "Timelines", s.count),
            AssistantFact("builders", "Builder timelines", s.builders),
            AssistantFact("wizards", "Wizard timelines", s.wizards),
            AssistantFact("changed", "Changed since the last export", s.changedSinceExport),
            AssistantFact("neverOpened", "Never opened", s.neverOpened),
        ]
        if let newest = s.newest { facts.append(AssistantFact("newest", "Newest", newest)) }
        if let name = s.newestChanged { facts.append(AssistantFact("newest.changed", "Newest changed", name)) }
        if let name = s.newestNeverOpened { facts.append(AssistantFact("newest.unopened", "Newest unopened", name)) }
        var summary = [AssistantText.count(s.count, "timeline")]
        if s.changedSinceExport > 0 { summary.append("\(s.changedSinceExport) changed since export") }
        return AssistantContext(page: pageName, facts: facts, summary: summary)
    }

    @MainActor
    func snapshot(store: AppStore) -> Snapshot {
        let timelines = Self.byEdit(store.timelines)
        let lastExport = store.generatedVideos.compactMap(\.generatedAt).max()
        let changed = Self.changed(timelines, lastExport: lastExport)
        let unopened = timelines.filter { $0.viewStateJSON == nil }
        return Snapshot(count: timelines.count, builders: timelines.count { !$0.isWizard },
                        wizards: timelines.count(where: \.isWizard), newest: timelines.first?.name,
                        changedSinceExport: changed.count, newestChanged: changed.first?.name,
                        neverOpened: unopened.count, newestNeverOpened: unopened.first?.name)
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext { Self.context(snapshot(store: store)) }

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        guard (context.int("timelines") ?? 0) > 0 else {
            return [.init(id: "timelines.none.empty", kind: .action, title: "New from Wizard",
                          reason: "This project has no timelines yet", actionID: "timelines.wizard")]
        }
        var rows: [AssistantSuggestion] = []
        let changed = context.int("changed") ?? 0
        if changed > 0, let name = context.value("newest.changed") {
            rows.append(.init(id: "timelines.render.pending", kind: .action, title: "Open \(name) to render",
                              reason: "\(AssistantText.count(changed, "timeline")) changed since the last export",
                              actionID: "timelines.open.changed"))
        }
        if let name = context.value("newest.unopened") {
            rows.append(.init(id: "timelines.open.newest", kind: .action, title: "Open \(name)",
                              reason: "The newest timeline you have not opened yet", actionID: "timelines.open.unopened"))
        }
        return rows
    }

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        func open(_ id: String, _ title: String, pick: @escaping @MainActor @Sendable (AppStore) -> TimelineRecord?) -> AssistantAction {
            AssistantAction(id: id, title: title, systemImage: SidebarSection.timelines.systemImage,
                            isAvailable: { pick($0) != nil }) { store in
                guard let timeline = pick(store) else { return .unavailable("No timeline to open.") }
                store.openTimelineRecord(timeline)
                return .handled("Opened \(timeline.name).")
            }
        }
        return [
            open("timelines.open.newest", "Open newest") { Self.byEdit($0.timelines).first },
            open("timelines.open.changed", "Open to render") { store in
                Self.changed(store.timelines, lastExport: store.generatedVideos.compactMap(\.generatedAt).max()).first
            },
            open("timelines.open.unopened", "Open unopened") { store in
                Self.byEdit(store.timelines).first { $0.viewStateJSON == nil }
            },
            AssistantAction(id: "timelines.new", title: "New Timeline", systemImage: "plus") { store in
                store.createTimeline()
                return .handled("Created a timeline.")
            },
            AssistantAction(id: "timelines.wizard", title: "New from Wizard", systemImage: "wand.and.stars") { store in
                store.selectSection(.wizard)
                return .handled("Opened the AI Wizard.")
            },
        ]
    }

    static func route(_ text: String) -> String? {
        let t = AssistantText.normalized(text)
        if t.isEmpty { return nil }
        if AssistantText.mentions(t, ["wizard", "generate", "ai "]) { return "timelines.wizard" }
        if AssistantText.mentions(t, ["render", "export"]) { return "timelines.open.changed" }
        // "newest" contains "new": opening is checked first.
        if AssistantText.mentions(t, ["open", "newest", "latest", "last", "recent"]) { return "timelines.open.newest" }
        if AssistantText.mentions(t, ["new", "create", "empty", "blank"]) { return "timelines.new" }
        return nil
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        AssistantText.run(Self.route(text), actions: actions(store: store), store: store,
                          fallback: AssistantText.unrecognized(page: page, examples: examples))
    }
}
