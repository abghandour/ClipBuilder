import Foundation

/// Ask AI on Instagram › Posts (InstagramView, posts tab): the saved
/// account's reels grid. Accounts and reels are on the store; the page
/// publishes which reels already taught the taste profile and the Learn
/// selection.
nonisolated struct InstagramPostsAssistant: PageAssistant {
    static let pageName = "Instagram Posts"
    let page = Self.pageName
    let examples = ["Learn my taste from the top reels",
                    "Refresh this account's reels",
                    "Open the best performing reel"]

    /// Below this many reels the top five are most of the account.
    static let learnThreshold = 5

    struct Snapshot: Equatable, Sendable {
        var accounts = 0
        var account: String?
        var isOwn = false
        var reels = 0
        var studied = 0
        var learnSelection = 0
        var fetching = false
        var studying = false
        var sort = "Recent"
    }

    static func context(_ s: Snapshot) -> AssistantContext {
        var facts = [
            AssistantFact("accounts", "Accounts", s.accounts),
            AssistantFact("reels", "Reels", s.reels),
            AssistantFact("studied", "Reels that taught the taste profile", s.studied),
            AssistantFact("learnSelection", "Ticked for Learn", s.learnSelection),
            AssistantFact("fetching", "Fetching", on: s.fetching),
            AssistantFact("studying", "Learning", on: s.studying),
        ]
        if let account = s.account {
            facts.insert(AssistantFact("account", "Account", "@\(account)"), at: 0)
            facts.insert(AssistantFact("account.own", "Own account", on: s.isOwn), at: 1)
        }
        var summary = [s.account.map { "@\($0)" } ?? "no account", AssistantText.count(s.reels, "reel"), s.sort]
        if s.studied > 0 { summary.append("\(s.studied) studied") }
        return AssistantContext(page: pageName, subpage: "Posts", facts: facts,
                                settings: [AssistantFact("sort", "Sort", s.sort)], summary: summary)
    }

    @MainActor
    func snapshot(store: AppStore) -> Snapshot {
        let state = store.assistant.state(page)
        let account = store.igAccounts.first { $0.id == store.igSelectedAccountID }
        return Snapshot(accounts: store.igAccounts.count, account: account?.username, isOwn: account?.isOwn ?? false,
                        reels: store.igMedia.count, studied: state.count("studied"),
                        learnSelection: state.count("learnSelection"), fetching: store.isFetchingInstagram,
                        studying: store.isStudyingTaste, sort: state.text("sort") ?? "Recent")
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext { Self.context(snapshot(store: store)) }

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        guard (context.int("accounts") ?? 0) > 0 else {
            return [.init(id: "instagram.account.none", kind: .action, title: "Add an Instagram account",
                          reason: "No accounts yet: add yours or any public one", actionID: "instagram.account.add")]
        }
        var rows: [AssistantSuggestion] = []
        let reels = context.int("reels") ?? 0
        if reels == 0, context.value("account") != nil, context.isOff("fetching") {
            rows.append(.init(id: "instagram.reels.none", kind: .action, title: "Fetch reels",
                              reason: "\(context.value("account") ?? "This account") has no reels loaded yet",
                              actionID: "instagram.refresh"))
        }
        if (context.int("learnSelection") ?? 0) > 0, context.isOff("studying") {
            rows.append(.init(id: "instagram.learn.selected", kind: .action, title: "Learn from the ticked reels",
                              reason: "\(AssistantText.count(context.int("learnSelection") ?? 0, "reel")) ticked for Learn",
                              actionID: "instagram.learn.selected"))
        } else if reels >= Self.learnThreshold, (context.int("studied") ?? 0) == 0, context.isOff("studying") {
            rows.append(.init(id: "instagram.taste.unstudied", kind: .action, title: "Learn from the top 5 reels",
                              reason: "\(reels) reels and none has taught the taste profile yet",
                              actionID: "instagram.learn.top"))
        }
        return rows
    }

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        let page = page
        let hasAccount: @MainActor @Sendable (AppStore) -> Bool = { store in
            store.igAccounts.contains { $0.id == store.igSelectedAccountID }
        }
        return [
            .command("instagram.account.add", "Add Account", "person.crop.circle", message: "Add an account."),
            AssistantAction(id: "instagram.refresh", title: "Refresh", systemImage: "arrow.clockwise",
                            isAvailable: { hasAccount($0) && !$0.isFetchingInstagram }) { store in
                guard let account = store.igAccounts.first(where: { $0.id == store.igSelectedAccountID }) else {
                    return .unavailable("Choose an account first.")
                }
                store.refreshInstagram(username: account.username)
                return .handled("Fetching @\(account.username).")
            },
            .command("instagram.learn.top", "Learn from Top 5 Quality Reels", "graduationcap",
                     message: "Learning from the top 5 reels.",
                     available: { !$0.isStudyingTaste && !$0.igMedia.isEmpty }),
            .command("instagram.learn.selected", "Learn from Selected", "graduationcap",
                     message: "Learning from the ticked reels.",
                     available: { !$0.isStudyingTaste && $0.assistant.state(page).count("learnSelection") > 0 }),
            AssistantAction(id: "instagram.lessons.distill", title: "Distill Performance Lessons", systemImage: "graduationcap",
                            isAvailable: { !$0.isDistillingPerformanceLessons }) { store in
                store.distillPerformanceLessons()
                return .handled("Distilling performance lessons.")
            },
            .command("instagram.reel.top", "Open the best reel", "play.rectangle.on.rectangle",
                     message: "Opened the best performing reel.", available: { !$0.igMedia.isEmpty }),
        ]
    }

    static func route(_ text: String) -> String? {
        let t = AssistantText.normalized(text)
        if t.isEmpty { return nil }
        if AssistantText.mentions(t, ["add account", "add an account", "new account", "follow"]) { return "instagram.account.add" }
        if AssistantText.mentions(t, ["distill", "what performs", "lesson"]) { return "instagram.lessons.distill" }
        if AssistantText.mentions(t, ["selected", "ticked"]) { return "instagram.learn.selected" }
        if AssistantText.mentions(t, ["learn", "taste", "study"]) { return "instagram.learn.top" }
        if AssistantText.mentions(t, ["refresh", "fetch", "update", "reload", "sync"]) { return "instagram.refresh" }
        if AssistantText.mentions(t, ["best", "top", "analyze", "open"]) { return "instagram.reel.top" }
        return nil
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        AssistantText.run(Self.route(text), actions: actions(store: store), store: store,
                          fallback: AssistantText.unrecognized(page: page, examples: examples))
    }
}
