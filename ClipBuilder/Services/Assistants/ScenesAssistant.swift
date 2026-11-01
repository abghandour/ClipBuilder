import Foundation

/// Ask AI on Scenes (ScenesView). The grid's filters, sort, selection and
/// counts live in the view's @State; the view publishes them.
nonisolated struct ScenesAssistant: PageAssistant {
    static let pageName = "Scenes"
    let page = Self.pageName
    let examples = ["Find scenes about the knockout",
                    "Pick my favorite scenes with AI",
                    "Sort by score and clear the filters"]

    /// Below this many scenes, judging favorites or sorting is not worth suggesting.
    static let manyScenes = 30

    struct Snapshot: Equatable, Sendable {
        var sceneCount = 0
        /// Cards the grid shows after filters.
        var visible = 0
        var favorites = 0
        var scored = 0
        var hidden = 0
        var selectedCount = 0
        var selected: [String] = []
        var favoritesOnly = false
        var showHidden = false
        var sortByScore = false
        /// Tag, score, sequence or hidden filter (the toolbar Filter icon is filled).
        var filtersActive = false
        var aiSearch = false
        var tag: String?
        var searchText = ""
        var batches = 0
        /// Non-favorite cards in view, the AI Favorites pool.
        var favoriteCandidates = 0
    }

    static func context(_ s: Snapshot) -> AssistantContext {
        let facts = [
            AssistantFact("scenes", "Scenes", s.sceneCount),
            AssistantFact("visible", "Shown", s.visible),
            AssistantFact("favorites", "Favorites", s.favorites),
            AssistantFact("scored", "Scored", s.scored),
            AssistantFact("hidden", "Hidden", s.hidden),
            AssistantFact("selected", "Selected", s.selectedCount),
            AssistantFact("favoriteCandidates", "AI Favorites pool", s.favoriteCandidates),
        ]
        var settings = [
            AssistantFact("favoritesOnly", "Favorites only", on: s.favoritesOnly),
            AssistantFact("showHidden", "Show hidden", on: s.showHidden),
            AssistantFact("sortByScore", "Top scored first", on: s.sortByScore),
            AssistantFact("filters", "Filters", on: s.filtersActive || s.favoritesOnly || !s.searchText.isEmpty || s.aiSearch),
            AssistantFact("aiSearch", "AI search", on: s.aiSearch),
            AssistantFact("batches", "Batches chosen", s.batches),
        ]
        if let tag = s.tag { settings.append(AssistantFact("tag", "Tag", tag)) }
        if !s.searchText.isEmpty { settings.append(AssistantFact("search", "Search", s.searchText)) }
        var summary = [s.visible == s.sceneCount ? AssistantText.count(s.sceneCount, "scene")
                       : "\(s.visible) of \(s.sceneCount) scenes"]
        if s.favorites > 0 { summary.append(AssistantText.count(s.favorites, "favorite")) }
        if let tag = s.tag { summary.append(tag) }
        if s.sortByScore { summary.append("top scored") }
        if s.selectedCount > 0 { summary.append("\(s.selectedCount) selected") }
        return AssistantContext(page: pageName, facts: facts, settings: settings,
                                selection: s.selectedCount > 0 ? s.selected : [], summary: summary)
    }

    @MainActor
    func snapshot(store: AppStore) -> Snapshot {
        let state = store.assistant.state(page)
        var s = Snapshot()
        s.sceneCount = state.counts["scenes"] ?? store.scenes.count
        s.visible = state.counts["visible"] ?? s.sceneCount
        s.favorites = state.count("favorites")
        s.scored = state.count("scored")
        s.hidden = state.count("hidden")
        s.selectedCount = state.count("selected")
        s.selected = state.selection ?? []
        s.favoritesOnly = state.flag("favoritesOnly")
        s.showHidden = state.flag("showHidden")
        s.sortByScore = state.flag("sortByScore")
        s.filtersActive = state.flag("filtersActive")
        s.aiSearch = state.flag("aiSearch")
        s.tag = state.text("tag")
        s.searchText = state.value("search") ?? ""
        s.batches = state.count("batches")
        s.favoriteCandidates = state.count("favoriteCandidates")
        return s
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext { Self.context(snapshot(store: store)) }

    // MARK: - Suggestions

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        let scenes = context.int("scenes") ?? 0
        guard scenes > 0 else {
            return [.init(id: "scenes.analyze.none", kind: .action, title: "Analyze a source",
                          reason: "No scenes yet: scenes come from analyzing sources", actionID: "scenes.goto.sources")]
        }
        var rows: [AssistantSuggestion] = []
        let visible = context.int("visible") ?? scenes
        if context.isOn("filters"), visible * 2 < scenes {
            rows.append(.init(id: "scenes.filter.active", kind: .action, title: "Clear filters",
                              reason: "Filters hide \(scenes - visible) of \(scenes) scenes", actionID: "scenes.filters.clear"))
        }
        if (context.int("favorites") ?? 0) == 0, scenes >= Self.manyScenes, (context.int("favoriteCandidates") ?? 0) > 0 {
            rows.append(.init(id: "scenes.favorites.none", kind: .action, title: "Pick favorites with AI",
                              reason: "\(scenes) scenes and none favorited yet", actionID: "scenes.favorites.ai"))
        }
        if context.isOff("sortByScore"), (context.int("scored") ?? 0) >= 10, scenes >= Self.manyScenes {
            rows.append(.init(id: "scenes.sort.time", kind: .setting, title: "Show top scored first",
                              reason: "\(context.int("scored") ?? 0) scenes have a score and the grid is in time order",
                              actionID: "scenes.sort.score"))
        }
        if scenes >= Self.manyScenes, context.isOff("aiSearch") {
            rows.append(.init(id: "scenes.search.example", kind: .action, title: "Describe a moment to find it",
                              reason: "Type “find scenes about …” here, or open Ask", actionID: "scenes.search"))
        }
        return rows
    }

    // MARK: - Actions

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        let page = page
        let state: @MainActor @Sendable (AppStore) -> AssistantPageState = { $0.assistant.state(page) }
        return [
            .command("scenes.favorites.ai", "AI Favorites", "checkmark.seal", message: "Opened AI Favorites.",
                     available: { state($0).count("favoriteCandidates") > 0 }),
            .command("scenes.search", "Ask", "sparkle.magnifyingglass", message: "Opened scene search.",
                     available: { !$0.scenes.isEmpty }),
            .command("scenes.filters.clear", "Clear filters", "line.3.horizontal.decrease.circle",
                     message: "Cleared the filters."),
            .command("scenes.sort.score", "Sort by score", "star", message: "Showing top scored first."),
            .command("scenes.generate", "Generate Video", "wand.and.stars", message: "Opened Generate Video.",
                     available: { state($0).count("visible") > 0 }),
            .open("scenes.goto.sources", .sources, title: "Open Sources"),
        ]
    }

    // MARK: - Free text

    enum Route: Equatable, Sendable {
        case action(String)
        /// Scene search with the words to look for.
        case search(String)
    }

    /// Keyword shortcuts only for complete, unambiguous requests. Anything
    /// that changes a filter or sort setting ("show only favorites"),
    /// negates ("turn off sort by score") or combines steps ("sort by score
    /// and clear the filters") returns nil and goes to the AI, which reads
    /// it against the settings whitelist and the action catalogue.
    static func route(_ text: String) -> Route? {
        let t = AssistantText.normalized(text)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        if t.isEmpty { return nil }
        func whole(_ pattern: String) -> Bool { t.range(of: "^(?:\(pattern))$", options: .regularExpression) != nil }
        let negated = t.range(of: #"\b(not|don't|dont|no|stop|without|turn off|switch off|disable|undo|remove)\b"#,
                              options: .regularExpression) != nil
        if negated { return nil }
        // A search names what to find; its words are the query, "and" included.
        let searchOpeners = ["find ", "search for ", "search ", "look for ", "show me ", "where "]
        if searchOpeners.contains(where: { t.hasPrefix($0) }) {
            // "show me only the favorites", "find favorites sorted by score": settings, not a query.
            let settingWords = #"\b(only|favou?rites?|hidden|sort(ed)?|filters?|tags?|top scored|by score)\b"#
            if t.range(of: settingWords, options: .regularExpression) != nil { return nil }
            let query = AssistantText.remainder(of: text, after: ["about ", "with ", "where ", "showing ", "look for ",
                                                                   "search for ", "find ", "search ", "show me "])
            return query.map(Route.search) ?? .action("scenes.search")
        }
        if whole("find|search|scene search|ask") { return .action("scenes.search") }
        if t.range(of: #"\b(and|then|also|plus)\b|,|&"#, options: .regularExpression) != nil { return nil }
        let favoritesRequest = whole(#"(pick|choose|select|suggest)( me)?( my| the)? (best |favou?rite |keeper )?(favou?rites?|keepers?|scenes?)( scenes)?( with ai| for me| using ai)?"#)
            && AssistantText.mentions(t, ["favorite", "favourite", "keeper"])
        if favoritesRequest || whole("(use )?ai favou?rites") {
            return .action("scenes.favorites.ai")
        }
        if whole(#"(clear|reset)( all)?( the)?( filters?| search)|show (all|every)( the)?( scenes)?"#) {
            return .action("scenes.filters.clear")
        }
        if whole(#"(sort|order)( them| the scenes)? by (score|rating)|(show )?(the )?top scored( scenes)?( first)?|(show )?(the )?best( scenes)? first|highest( scored)? first"#) {
            return .action("scenes.sort.score")
        }
        if whole(#"(generate|make|build|create)( me)? (a )?(video|reel)( from (these|this|them|the selection|the selected scenes|selected scenes|the scenes shown))?"#) {
            return .action("scenes.generate")
        }
        return nil
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        switch Self.route(text) {
        case .search(let query):
            guard !store.scenes.isEmpty else { return .unavailable("Analyze a source first: there are no scenes to search.") }
            store.assistant.sendCommand("scenes.search", text: query)
            return .started(jobTitle: "Scene Search — \(query)")
        case .action(let id):
            return AssistantText.run(id, actions: actions(store: store), store: store,
                                     fallback: AssistantText.unrecognized(page: page, examples: examples))
        case nil:
            return AssistantText.unrecognized(page: page, examples: examples)
        }
    }

    // MARK: - Settings Ask AI may change (Phase 3)

    /// `tagFilter` value that clears the tag filter.
    static let anyTag = "any"
    static let tagLimit = 150
    static let searchLimit = 100

    /// `favoritesOnly`, `tagFilter` (the grid's own tags, most used first),
    /// `searchText`, `sortByScore`.
    static func settings(tags: [String]) -> [AssistantSetting] {
        [AssistantSetting("favoritesOnly", "Favorites only", .bool),
         AssistantSetting("tagFilter", "Tag filter", .choice([anyTag] + tags.prefix(tagLimit)),
                          choiceLabels: [anyTag: "no tag filter"]),
         AssistantSetting("searchText", "Search text", .text(maxLength: searchLimit)),
         AssistantSetting("sortByScore", "Top scored first", .bool)]
    }

    /// Tags by how many scenes carry them, then by name.
    static func tagsByUse(_ scenes: [[String]]) -> [String] {
        var counts: [String: Int] = [:]
        for tags in scenes { for tag in Set(tags) { counts[tag, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    @MainActor
    func assistSettings(store: AppStore) -> [AssistantSetting] {
        Self.settings(tags: Self.tagsByUse(store.historyScenes.map(\.tags)))
    }

    /// The grid's filters are ScenesView @State: the view applies the patch.
    @MainActor
    func apply(settings: [String: String], store: AppStore) -> AskAIOutcome {
        store.assistant.sendSettings(settings, namespace: "scenes", message: "Updated the Scenes filters.")
    }
}
