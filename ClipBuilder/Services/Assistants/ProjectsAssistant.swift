import Foundation

/// Ask AI on the Projects home (ProjectsHomeView). Project counts are on
/// the store; the content gaps report lives on AI Lessons and the Starting
/// Style interview in Settings › Taste, so those actions go there.
nonisolated struct ProjectsAssistant: PageAssistant {
    static let pageName = "Projects"
    let page = Self.pageName
    let examples = ["Open the project I worked on last",
                    "Create a new project",
                    "What should I post next?"]

    struct Snapshot: Equatable, Sendable {
        var active = 0
        var archived = 0
        /// Sources in the Home project (every source of the profile).
        var homeSources = 0
        var recentID: Int64?
        var recentName: String?
        var tasteSet = false
        /// "2026-11": the gaps report suggestion comes back each month.
        var month = ""
    }

    static func month(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// The active project opened most recently; created date breaks ties.
    static func mostRecent(_ projects: [ProjectRecord]) -> ProjectRecord? {
        projects.filter { !$0.archived && !$0.isHome }
            .max { ($0.lastOpenedAt ?? $0.createdAt ?? "") < ($1.lastOpenedAt ?? $1.createdAt ?? "") }
    }

    static func context(_ s: Snapshot) -> AssistantContext {
        var facts = [AssistantFact("active", "Active projects", s.active), AssistantFact("archived", "Archived", s.archived),
                     AssistantFact("homeSources", "Sources in Home", s.homeSources),
                     AssistantFact("taste", "Taste set", on: s.tasteSet), AssistantFact("month", "Month", s.month)]
        if let id = s.recentID, let name = s.recentName {
            facts += [AssistantFact("recent.id", "Last opened id", String(id)), AssistantFact("recent", "Last opened", name)]
        }
        var summary = ["\(s.active) active", "\(s.archived) archived"]
        if let name = s.recentName { summary.append("last: \(name)") }
        return AssistantContext(page: pageName, facts: facts, summary: summary)
    }

    @MainActor
    func snapshot(store: AppStore, now: Date = Date()) -> Snapshot {
        let profile = store.activeProfile
        let recent = Self.mostRecent(store.projects)
        return Snapshot(active: store.projects.count { !$0.archived && !$0.isHome },
                        archived: store.projects.count(where: \.archived),
                        homeSources: store.projects.first(where: \.isHome)?.sourceCount ?? 0,
                        recentID: recent?.id, recentName: recent?.name,
                        tasteSet: !profile.tasteRubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !profile.houseStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        month: Self.month(now))
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext { Self.context(snapshot(store: store)) }

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        var rows: [AssistantSuggestion] = []
        let active = context.int("active") ?? 0
        if active == 0 {
            let home = context.int("homeSources") ?? 0
            rows.append(.init(id: "projects.new.none", kind: .action, title: "Create a project",
                              reason: home > 0 ? "\(AssistantText.count(home, "source")) in Home and no project to group them"
                                  : "No projects yet: a project groups the sources for one show or event",
                              actionID: "projects.new"))
        } else if let id = context.value("recent.id"), let name = context.value("recent") {
            rows.append(.init(id: "projects.open.p\(id)", kind: .action, title: "Open \(name)",
                              reason: "The project you opened last", actionID: "projects.open.recent"))
        }
        if context.isOff("taste") {
            rows.append(.init(id: "projects.starter.missing", kind: .action, title: "Generate a Starting Style",
                              reason: "This profile has no taste rubric or house style yet", actionID: "projects.starter"))
        }
        if active > 0, let month = context.value("month"), !month.isEmpty {
            rows.append(.init(id: "projects.gaps.\(month)", kind: .action, title: "Check content gaps",
                              reason: "The monthly look at what to post next and what blocks output", actionID: "projects.gaps"))
        }
        return rows
    }

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        [
            .command("projects.new", "New Project", "plus", message: "Name the new project."),
            AssistantAction(id: "projects.open.recent", title: "Open last project", systemImage: SidebarSection.projects.systemImage,
                            isAvailable: { Self.mostRecent($0.projects) != nil }) { store in
                guard let project = Self.mostRecent(store.projects) else { return .unavailable("No project to open.") }
                store.selectProject(project.id)
                return .handled("Opened \(project.name).")
            },
            .command("projects.starter", "Generate Starting Style", "graduationcap",
                     message: "Opened Settings › Taste: press Generate Starting Style."),
            AssistantAction(id: "projects.gaps", title: "Content Gaps", systemImage: "checklist") { store in
                store.selectSection(.learned)
                store.assistant.sendCommand("lessons.gaps")
                return .handled("Opened Content Gaps.")
            },
        ]
    }

    static func route(_ text: String) -> String? {
        let t = AssistantText.normalized(text)
        if t.isEmpty { return nil }
        if AssistantText.mentions(t, ["post next", "gap", "what should i", "blocking"]) { return "projects.gaps" }
        if AssistantText.mentions(t, ["starting style", "starter", "taste", "house style"]) { return "projects.starter" }
        if AssistantText.mentions(t, ["new", "create", "start a project"]) { return "projects.new" }
        if AssistantText.mentions(t, ["open", "last", "recent", "continue", "worked on"]) { return "projects.open.recent" }
        return nil
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        AssistantText.run(Self.route(text), actions: actions(store: store), store: store,
                          fallback: AssistantText.unrecognized(page: page, examples: examples))
    }
}

/// Ask AI on AI Lessons (LearnedPreferencesView). Review and onboarding
/// counts come from the page's loaded document; rules are on the store.
nonisolated struct LessonsAssistant: PageAssistant {
    static let pageName = "AI Lessons"
    let page = Self.pageName
    let examples = ["Distill rules from my reviews",
                    "Publish my lessons to the team",
                    "What should I post next?"]

    /// Reviews it takes before distilling is worth suggesting.
    static let distillReviews = 5

    struct Snapshot: Equatable, Sendable {
        var lessons = 0
        var pinned = 0
        var reviews = 0
        var onboardingDone = 0
        var onboardingTotal = 0
        var hasHome = false
        var hasNickname = false
        /// Teammates' published documents found in the Drive home.
        var contributors = 0
        var distilling = false
        var busy = false
    }

    static func context(_ s: Snapshot) -> AssistantContext {
        let facts = [
            AssistantFact("lessons", "Rules", s.lessons), AssistantFact("pinned", "Pinned rules", s.pinned),
            AssistantFact("distilled", "Distilled rules", s.lessons - s.pinned),
            AssistantFact("reviews", "Reels reviewed", s.reviews),
            AssistantFact("onboarding.done", "Sources feeding the Wizard", s.onboardingDone),
            AssistantFact("onboarding.total", "Possible sources", s.onboardingTotal),
            AssistantFact("home", "Drive home", on: s.hasHome), AssistantFact("nickname", "Device nickname", on: s.hasNickname),
            AssistantFact("contributors", "Teammates' documents", s.contributors),
            AssistantFact("distilling", "Distilling", on: s.distilling), AssistantFact("busy", "Busy", on: s.busy),
        ]
        var summary = [AssistantText.count(s.lessons, "rule"), AssistantText.count(s.reviews, "review")]
        if s.onboardingTotal > 0 { summary.append("\(s.onboardingDone) of \(s.onboardingTotal) feeding the Wizard") }
        return AssistantContext(page: pageName, facts: facts, summary: summary)
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext {
        let state = store.assistant.state(page)
        return Self.context(Snapshot(lessons: store.lessons.count, pinned: store.lessons.count(where: \.pinned),
                                     reviews: state.count("reviews"), onboardingDone: state.count("onboarding.done"),
                                     onboardingTotal: state.count("onboarding.total"), hasHome: state.flag("home"),
                                     hasNickname: state.flag("nickname"), contributors: state.count("contributors"),
                                     distilling: store.isDistillingLessons, busy: state.flag("busy")))
    }

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        var rows: [AssistantSuggestion] = []
        let reviews = context.int("reviews") ?? 0
        if reviews >= Self.distillReviews, (context.int("distilled") ?? 0) == 0, context.isOff("distilling") {
            rows.append(.init(id: "lessons.distill.undistilled", kind: .action, title: "Distill rules from reviews",
                              reason: "\(reviews) reels reviewed and no distilled rules yet", actionID: "lessons.distill"))
        }
        if context.isOn("home"), context.isOn("nickname"), (context.int("contributors") ?? 0) == 0,
           (context.int("lessons") ?? 0) > 0 {
            rows.append(.init(id: "lessons.publish.none", kind: .action, title: "Publish to the team",
                              reason: "No teammate has published lessons to this profile's Drive home yet",
                              actionID: "lessons.publish"))
        }
        let done = context.int("onboarding.done") ?? 0
        let total = context.int("onboarding.total") ?? 0
        if total > 0, done < total {
            rows.append(.init(id: "lessons.onboarding.incomplete", kind: .insight, title: "\(done) of \(total) sources feed the Wizard",
                              reason: "The checklist at the top of this page lists what is missing"))
        }
        return rows
    }

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        let page = page
        return [
            AssistantAction(id: "lessons.distill", title: "Distill rules from reviews", systemImage: "sparkles",
                            isAvailable: { !$0.isDistillingLessons && !$0.assistant.state(page).flag("busy") }) { store in
                store.distillLessons()
                return .handled("Distilling rules from your reviews.")
            },
            AssistantAction(id: "lessons.publish", title: "Publish now", systemImage: "icloud.and.arrow.up",
                            isAvailable: { store in
                                let state = store.assistant.state(page)
                                return state.flag("home") && state.flag("nickname") && !state.flag("busy")
                            }) { store in
                store.startPublishingLessons()
                return .started(jobTitle: "Publish lessons")
            },
            .command("lessons.gaps", "Content Gaps", "checklist", message: "Opened Content Gaps."),
            .command("lessons.rules", "Manage Learned Rules", "brain.head.profile", message: "Opened Settings › Taste."),
        ]
    }

    static func route(_ text: String) -> String? {
        let t = AssistantText.normalized(text)
        if t.isEmpty { return nil }
        if AssistantText.mentions(t, ["distill", "from my reviews", "from reviews"]) { return "lessons.distill" }
        if AssistantText.mentions(t, ["publish", "share", "team"]) { return "lessons.publish" }
        if AssistantText.mentions(t, ["post next", "gap", "blocking", "what should i"]) { return "lessons.gaps" }
        if AssistantText.mentions(t, ["manage", "edit rules", "rules", "settings"]) { return "lessons.rules" }
        return nil
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        AssistantText.run(Self.route(text), actions: actions(store: store), store: store,
                          fallback: AssistantText.unrecognized(page: page, examples: examples))
    }
}
