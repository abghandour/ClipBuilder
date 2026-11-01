import Foundation

/// Ask AI on Exports (LibraryView). The folder, sort and the per-video gaps
/// in the shown folder come from the page; each action opens the same
/// sheet or Builder hand-off as the video card's own button. Suggestions
/// (and the plain actions) target the newest video in the folder that needs
/// it; an explicit "newest/latest" request targets the newest video itself
/// (the `.newest` actions) and says why when that video cannot, rather than
/// quietly picking an older one. Every action is a page command, resolved
/// by the page against the folder after any folder change in the same answer.
nonisolated struct ExportsAssistant: PageAssistant {
    static let pageName = "Exports"
    let page = Self.pageName
    let examples = ["Publish the newest one",
                    "Pick a cover frame for the latest video",
                    "Write post text for videos without a caption"]

    /// The newest video in the shown folder for each kind of gap, by id.
    struct Targets: Equatable, Sendable {
        var newest: Int64?
        var cover: Int64?
        var flagged: Int64?
        var noText: Int64?
        var publish: Int64?
        var hooks: Int64?
        var review: Int64?
    }

    struct Snapshot: Equatable, Sendable {
        var total = 0
        var shown = 0
        var folder = "all"
        var sort = "Newest"
        var withoutCover = 0
        var flagged = 0
        var withoutText = 0
        /// Publishable and not yet on Instagram.
        var unpublished = 0
        /// Failing the quality gate: the card shows Review instead of Publish.
        var needsReview = 0
        var hookGroups = 0
        var newest: String?
    }

    /// Pure: newest first, the order `store.generatedVideos` keeps.
    static func targets(_ videos: [GeneratedVideoRecord]) -> Targets {
        Targets(newest: videos.first?.id,
                cover: videos.first { $0.coverTime == nil }?.id,
                flagged: videos.first { !$0.reviewFlags.isEmpty }?.id,
                noText: videos.first { $0.caption.isEmpty }?.id,
                publish: videos.first { $0.instagramMediaID == nil && isPublishable($0) }?.id,
                hooks: videos.first { $0.variantGroupID != nil }?.id,
                review: videos.first { !isPublishable($0) }?.id ?? videos.first?.id)
    }

    /// The shown folder's gaps for the page to publish: counts by fact key
    /// and the targets. Pure; the page memoizes it.
    struct Tally: Equatable, Sendable {
        var counts: [String: Int] = [:]
        var targets = Targets()
    }

    static func tally(_ videos: [GeneratedVideoRecord]) -> Tally {
        var counts = ["shown": videos.count, "cover.missing": 0, "flagged": 0, "text.missing": 0,
                      "unpublished": 0, "review": 0, "hookGroups": 0]
        var groups: Set<String> = []
        for video in videos {
            let publishable = isPublishable(video)
            if video.coverTime == nil { counts["cover.missing", default: 0] += 1 }
            if !video.reviewFlags.isEmpty { counts["flagged", default: 0] += 1 }
            if video.caption.isEmpty { counts["text.missing", default: 0] += 1 }
            if publishable, video.instagramMediaID == nil { counts["unpublished", default: 0] += 1 }
            if !publishable { counts["review", default: 0] += 1 }
            if let group = video.variantGroupID { groups.insert(group) }
        }
        counts["hookGroups"] = groups.count
        return Tally(counts: counts, targets: targets(videos))
    }

    static func isPublishable(_ video: GeneratedVideoRecord) -> Bool {
        video.qualityReport.map { $0.verdict == .publishable } ?? true
    }

    static func context(_ s: Snapshot) -> AssistantContext {
        var facts = [
            AssistantFact("videos", "Videos", s.total),
            AssistantFact("shown", "In this folder", s.shown),
            AssistantFact("cover.missing", "Without a cover frame", s.withoutCover),
            AssistantFact("flagged", "With review flags", s.flagged),
            AssistantFact("text.missing", "Without post text", s.withoutText),
            AssistantFact("unpublished", "Ready, not published", s.unpublished),
            AssistantFact("review", "Failing the quality gate", s.needsReview),
            AssistantFact("hookGroups", "Hook comparisons", s.hookGroups),
        ]
        if let newest = s.newest { facts.append(AssistantFact("newest", "Newest", newest)) }
        let settings = [AssistantFact("folder", "Folder", s.folder), AssistantFact("sort", "Sort", s.sort)]
        var summary = [s.folder == "all" ? "All" : s.folder, "\(s.shown) of \(s.total) videos", s.sort]
        if s.unpublished > 0 { summary.append("\(s.unpublished) ready to publish") }
        return AssistantContext(page: pageName, facts: facts, settings: settings, summary: summary)
    }

    @MainActor
    func snapshot(store: AppStore) -> Snapshot {
        let state = store.assistant.state(page)
        var s = Snapshot()
        s.total = store.generatedVideos.count
        s.shown = state.counts["shown"] ?? s.total
        s.folder = state.value("folder") ?? "all"
        s.sort = store.outputsSort.isEmpty ? "Newest" : store.outputsSort
        s.withoutCover = state.count("cover.missing")
        s.flagged = state.count("flagged")
        s.withoutText = state.count("text.missing")
        s.unpublished = state.count("unpublished")
        s.needsReview = state.count("review")
        s.hookGroups = state.count("hookGroups")
        s.newest = state.text("newest")
        return s
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext { Self.context(snapshot(store: store)) }

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        guard (context.int("videos") ?? 0) > 0 else {
            return [.init(id: "exports.none.empty", kind: .action, title: "Generate a video",
                          reason: "No exports yet: the AI Wizard renders them", actionID: "exports.goto.wizard")]
        }
        guard (context.int("shown") ?? 0) > 0 else { return [] }
        var rows: [AssistantSuggestion] = []
        func count(_ key: String) -> Int { context.int(key) ?? 0 }
        if count("flagged") > 0 {
            rows.append(.init(id: "exports.flags.pending", kind: .action, title: "Check flagged moments",
                              reason: "\(AssistantText.count(count("flagged"), "video")) \(count("flagged") == 1 ? "has" : "have") moments the pipeline was unsure about",
                              actionID: "exports.flags"))
        }
        if count("unpublished") > 0 {
            rows.append(.init(id: "exports.publish.ready", kind: .action, title: "Publish to Instagram",
                              reason: "\(AssistantText.count(count("unpublished"), "video")) passed the quality checks and \(count("unpublished") == 1 ? "is" : "are") not published",
                              actionID: "exports.publish"))
        }
        if count("cover.missing") > 0 {
            rows.append(.init(id: "exports.cover.missing", kind: .action, title: "Pick a cover frame",
                              reason: "\(AssistantText.count(count("cover.missing"), "video")) \(count("cover.missing") == 1 ? "uses" : "use") a near-start frame as cover",
                              actionID: "exports.cover"))
        }
        if count("text.missing") > 0 {
            rows.append(.init(id: "exports.text.missing", kind: .action, title: "Write post text",
                              reason: "\(AssistantText.count(count("text.missing"), "video")) \(count("text.missing") == 1 ? "has" : "have") no caption to post with",
                              actionID: "exports.text"))
        }
        if count("hookGroups") == 0 {
            rows.append(.init(id: "exports.hooks.none", kind: .action, title: "Try other openings",
                              reason: "No hook comparison in this folder: open the newest video in the Builder to make hook variants",
                              actionID: "exports.builder"))
        }
        return rows
    }

    /// Why the newest video cannot take `actionID` (a `.newest` action), or nil.
    static func newestProblem(_ actionID: String, name: String, published: Bool, publishable: Bool) -> String? {
        switch actionID {
        case "exports.publish.newest":
            if published { return "The newest video, \(name), is already on Instagram." }
            if !publishable { return "The newest video, \(name), did not pass the quality checks. Review it before publishing." }
            return nil
        default:
            return nil
        }
    }

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        let page = page
        func has(_ key: String) -> @MainActor @Sendable (AppStore) -> Bool { { $0.assistant.state(page).text(key) != nil } }
        let newest = has("target.newest")
        return [
            .command("exports.publish", "Publish to Instagram", "paperplane", message: "Opened Publish.",
                     available: has("target.publish")),
            .command("exports.cover", "Pick Cover Frame", "rectangle.on.rectangle", message: "Opened the cover frame picker.",
                     available: has("target.cover")),
            .command("exports.review", "Review", "hand.thumbsup", message: "Opened Review.", available: has("target.review")),
            .command("exports.flags", "Open flagged in Builder", "flag.fill", message: "Opening in the Builder.",
                     available: has("target.flagged")),
            .command("exports.builder", "Open in Builder", "timeline.selection", message: "Opening in the Builder.",
                     available: has("target.newest")),
            .command("exports.hooks.compare", "Compare hooks", "rectangle.split.3x1", message: "Opened the hook comparison.",
                     available: has("target.hooks")),
            // A page command like the rest: with a folder change in the same
            // answer, the page picks the video in the new folder.
            .command("exports.text", "Write Post Text", "text.bubble", message: "Writing post text.",
                     available: has("target.noText")),
            .command("exports.publish.newest", "Publish the newest video", "paperplane",
                     message: "Opened Publish for the newest video.", available: newest),
            .command("exports.cover.newest", "Pick a cover for the newest video", "rectangle.on.rectangle",
                     message: "Opened the cover frame picker for the newest video.", available: newest),
            .command("exports.text.newest", "Write post text for the newest video", "text.bubble",
                     message: "Writing post text for the newest video.", available: newest),
            .open("exports.goto.wizard", .wizard, title: "Open the AI Wizard"),
        ]
    }

    /// Words that name the newest video itself, not "one that needs it".
    static let newestWords = ["newest", "latest", "most recent", "last video", "last one", "last export"]

    static func route(_ text: String) -> String? {
        let t = AssistantText.normalized(text)
        if t.isEmpty { return nil }
        let newest = AssistantText.mentions(t, newestWords) ? ".newest" : ""
        if AssistantText.mentions(t, ["publish", "post it", "instagram", "upload"]) { return "exports.publish" + newest }
        if AssistantText.mentions(t, ["cover", "thumbnail"]) { return "exports.cover" + newest }
        if AssistantText.mentions(t, ["caption", "post text", "write"]) { return "exports.text" + newest }
        if AssistantText.mentions(t, ["flag"]) { return "exports.flags" }
        if AssistantText.mentions(t, ["hook"]) { return "exports.hooks.compare" }
        if AssistantText.mentions(t, ["review", "feedback", "rate"]) { return "exports.review" }
        if AssistantText.mentions(t, ["builder", "edit", "open"]) { return "exports.builder" }
        if AssistantText.mentions(t, ["generate", "wizard", "new video"]) { return "exports.goto.wizard" }
        return nil
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        let id = Self.route(text)
        let state = store.assistant.state(page)
        if let id, let name = state.text("newest"),
           let problem = Self.newestProblem(id, name: name, published: state.flag("newest.published"),
                                            publishable: state.flags["newest.publishable"] ?? true) {
            return .unavailable(problem)
        }
        return AssistantText.run(id, actions: actions(store: store), store: store,
                                 fallback: AssistantText.unrecognized(page: page, examples: examples))
    }

    // MARK: - Settings Ask AI may change (Phase 3)

    static let folderLimit = 80

    /// The folder list as the page publishes it under "folders": id and
    /// title separated by U+001F, folders by U+001E.
    static func encodeFolders(_ folders: [(id: String, title: String)]) -> String {
        folders.prefix(folderLimit).map { "\($0.id)\u{1F}\($0.title)" }.joined(separator: "\u{1E}")
    }

    static func decodeFolders(_ raw: String?) -> [(id: String, title: String)] {
        (raw ?? "").split(separator: "\u{1E}").compactMap { entry in
            let parts = entry.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard let id = parts.first, !id.isEmpty else { return nil }
            return (String(id), parts.count > 1 ? String(parts[1]) : String(id))
        }
    }

    /// `selectedFolder`: one of the folders the page shows.
    static func settings(folders: [(id: String, title: String)]) -> [AssistantSetting] {
        let folders = folders.isEmpty ? [("all", "All")] : folders
        return [AssistantSetting("selectedFolder", "Folder", .choice(folders.map(\.0)),
                                 choiceLabels: Dictionary(folders.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first }))]
    }

    @MainActor
    func assistSettings(store: AppStore) -> [AssistantSetting] {
        Self.settings(folders: Self.decodeFolders(store.assistant.state(page).text("folders")))
    }

    /// The folder is LibraryView @State: the view applies the patch.
    @MainActor
    func apply(settings: [String: String], store: AppStore) -> AskAIOutcome {
        store.assistant.sendSettings(settings, namespace: "exports", message: "Changed the Exports folder.")
    }
}
