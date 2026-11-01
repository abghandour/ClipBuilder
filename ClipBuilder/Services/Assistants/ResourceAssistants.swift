import Foundation

// Ask AI on the resource pages: Screen Layouts, Transitions, Effects (Looks),
// Text Looks, and the Bumpers / Images / Music asset browsers. Each page
// publishes its item counts; the actions are its toolbar buttons.

// MARK: - Screen Layouts

nonisolated struct ScreenLayoutsAssistant: PageAssistant {
    static let pageName = "Screen Layouts"
    let page = Self.pageName
    let examples = ["Create a new screen layout",
                    "Let the AI Wizard use my layouts",
                    "Show the layout files in Finder"]

    struct Snapshot: Equatable, Sendable {
        var saved = 0
        var builtIn = 0
        /// Layouts with at least one area: what AI Availability lists.
        var usable = 0
        var aiEnabled = false
        var selected: String?
    }

    static func context(_ s: Snapshot) -> AssistantContext {
        var facts = [AssistantFact("saved", "Your layouts", s.saved), AssistantFact("builtIn", "Built-in layouts", s.builtIn),
                     AssistantFact("usable", "Layouts with areas", s.usable)]
        if let selected = s.selected { facts.append(AssistantFact("selected", "Selected", selected)) }
        return AssistantContext(page: pageName, facts: facts,
                                settings: [AssistantFact("aiEnabled", "Multi-panel layouts for the AI", on: s.aiEnabled)],
                                selection: s.selected.map { [$0] } ?? [],
                                summary: [AssistantText.count(s.saved, "saved layout"),
                                          "AI layouts \(s.aiEnabled ? "on" : "off")"])
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext {
        let state = store.assistant.state(page)
        return Self.context(Snapshot(saved: state.count("saved"), builtIn: state.count("builtIn"),
                                     usable: state.count("usable"), aiEnabled: state.flag("aiEnabled"),
                                     selected: state.text("selected")))
    }

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        var rows: [AssistantSuggestion] = []
        if (context.int("saved") ?? 0) == 0 {
            rows.append(.init(id: "layouts.saved.none", kind: .action, title: "Create a screen layout",
                              reason: "Only built-in layouts so far: draw named areas for screen recordings",
                              actionID: "layouts.new"))
        }
        if (context.int("usable") ?? 0) > 0, context.isOff("aiEnabled") {
            rows.append(.init(id: "layouts.ai.off", kind: .setting, title: "Allow multi-panel layouts",
                              reason: "\(AssistantText.count(context.int("usable") ?? 0, "layout")) with areas, and the AI Wizard may not use any",
                              actionID: "layouts.ai.on"))
        }
        return rows
    }

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        [.command("layouts.new", "New Screen Layout", "plus", message: "Created a screen layout."),
         .command("layouts.ai.on", "Allow multi-panel layouts", "wand.and.stars", message: "The AI Wizard may use multi-panel layouts."),
         .command("layouts.finder", "Show in Finder", "folder", message: "Opened the layouts folder.")]
    }

    static func route(_ text: String) -> String? {
        let t = AssistantText.normalized(text)
        if t.isEmpty { return nil }
        if AssistantText.mentions(t, ["finder", "folder", "files"]) { return "layouts.finder" }
        if AssistantText.mentions(t, ["allow", "wizard", "ai ", "enable", "use my"]) { return "layouts.ai.on" }
        if AssistantText.mentions(t, ["new", "create", "draw", "add"]) { return "layouts.new" }
        return nil
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        AssistantText.run(Self.route(text), actions: actions(store: store), store: store,
                          fallback: AssistantText.unrecognized(page: page, examples: examples))
    }
}

// MARK: - Transitions (sidebar Effects › Transitions, TransitionsView)

nonisolated struct TransitionsAssistant: PageAssistant {
    static let pageName = "Transitions"
    let page = Self.pageName
    let examples = ["Render all transition previews",
                    "Let the AI choose any transition",
                    "Use hard cuts only"]

    struct Snapshot: Equatable, Sendable {
        var effects = 0
        var previews = 0
        var rendering = false
        var limited = false
        /// Transitions the AI Wizard may use when limited.
        var allowed = 0
        var tab = ""
    }

    static func context(_ s: Snapshot) -> AssistantContext {
        let palette = !s.limited ? "any" : s.allowed == 0 ? "hard cuts only" : "\(s.allowed) allowed"
        return AssistantContext(
            page: pageName,
            facts: [AssistantFact("effects", "Transitions", s.effects), AssistantFact("previews", "Rendered previews", s.previews),
                    AssistantFact("rendering", "Rendering", on: s.rendering)],
            settings: [AssistantFact("palette", "AI palette", palette), AssistantFact("allowed", "Allowed", s.allowed),
                       AssistantFact("tab", "Category", s.tab)],
            summary: [s.tab, "\(s.previews) of \(s.effects) previews", "AI palette: \(palette)"])
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext {
        let state = store.assistant.state(page)
        return Self.context(Snapshot(effects: state.count("effects"), previews: state.count("previews"),
                                     rendering: state.flag("rendering"), limited: state.flag("limited"),
                                     allowed: state.count("allowed"), tab: state.text("tab") ?? ""))
    }

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        var rows: [AssistantSuggestion] = []
        let effects = context.int("effects") ?? 0
        let previews = context.int("previews") ?? 0
        if effects > 0, previews < effects, context.isOff("rendering") {
            rows.append(.init(id: "transitions.previews.missing", kind: .action, title: "Render all previews",
                              reason: "\(effects - previews) of \(effects) transitions have no preview yet",
                              actionID: "transitions.render"))
        }
        if context.value("palette") == "hard cuts only" {
            rows.append(.init(id: "transitions.palette.cutsOnly", kind: .setting, title: "Let the AI choose any transition",
                              reason: "The AI Wizard is limited to hard cuts", actionID: "transitions.palette.all"))
        }
        return rows
    }

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        let page = page
        return [.command("transitions.render", "Render All Previews", "play.rectangle.on.rectangle",
                         message: "Rendering every transition preview.",
                         available: { !$0.assistant.state(page).flag("rendering") }),
                .command("transitions.palette.all", "Let AI Choose Any Effect", "wand.and.stars",
                         message: "The AI Wizard may use any transition."),
                .command("transitions.palette.cuts", "Hard Cuts Only", "wand.and.stars",
                         message: "The AI Wizard uses hard cuts only."),
                .command("transitions.finder", "Show in Finder", "folder", message: "Opened the previews folder.")]
    }

    static func route(_ text: String) -> String? {
        let t = AssistantText.normalized(text)
        if t.isEmpty { return nil }
        if AssistantText.mentions(t, ["hard cut", "cuts only", "no transitions"]) { return "transitions.palette.cuts" }
        if AssistantText.mentions(t, ["any", "all transitions", "choose", "palette"]) { return "transitions.palette.all" }
        if AssistantText.mentions(t, ["render", "preview"]) { return "transitions.render" }
        if AssistantText.mentions(t, ["finder", "folder"]) { return "transitions.finder" }
        return nil
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        AssistantText.run(Self.route(text), actions: actions(store: store), store: store,
                          fallback: AssistantText.unrecognized(page: page, examples: examples))
    }
}

// MARK: - Effects (sidebar Effects › Looks, LooksView)

nonisolated struct LooksAssistant: PageAssistant {
    static let pageName = "Effects"
    let page = Self.pageName
    let examples = ["Render all effect previews",
                    "Change the sample video",
                    "Preview every look on my footage"]

    struct Snapshot: Equatable, Sendable {
        var available = 0
        var previews = 0
        var rendering = false
        var sample: String?
    }

    static func context(_ s: Snapshot) -> AssistantContext {
        var facts = [AssistantFact("available", "Available effects", s.available),
                     AssistantFact("previews", "Rendered previews", s.previews),
                     AssistantFact("rendering", "Rendering", on: s.rendering)]
        if let sample = s.sample { facts.append(AssistantFact("sample", "Sample video", sample)) }
        return AssistantContext(page: pageName, facts: facts,
                                summary: ["\(s.previews) of \(s.available) previews", s.sample ?? "default sample"])
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext {
        let state = store.assistant.state(page)
        return Self.context(Snapshot(available: state.count("available"), previews: state.count("previews"),
                                     rendering: state.flag("rendering"), sample: state.text("sample")))
    }

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        let available = context.int("available") ?? 0
        let previews = context.int("previews") ?? 0
        guard available > 0, previews < available, context.isOff("rendering") else { return [] }
        return [.init(id: "looks.previews.missing", kind: .action, title: "Render all previews",
                      reason: "\(available - previews) of \(available) effects have no preview yet",
                      actionID: "looks.render")]
    }

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        let page = page
        return [.command("looks.render", "Render All Previews", "play.rectangle.on.rectangle",
                         message: "Rendering every effect preview.",
                         available: { !$0.assistant.state(page).flag("rendering") && $0.database != nil }),
                .command("looks.sample", "Change Sample", "film", message: "Choose a sample video.")]
    }

    static func route(_ text: String) -> String? {
        let t = AssistantText.normalized(text)
        if t.isEmpty { return nil }
        if AssistantText.mentions(t, ["sample", "my footage", "different video"]) { return "looks.sample" }
        if AssistantText.mentions(t, ["render", "preview"]) { return "looks.render" }
        return nil
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        AssistantText.run(Self.route(text), actions: actions(store: store), store: store,
                          fallback: AssistantText.unrecognized(page: page, examples: examples))
    }
}

// MARK: - Text Looks (TextLooksView)

nonisolated struct TextLooksAssistant: PageAssistant {
    static let pageName = "Text Looks"
    let page = Self.pageName
    let examples = ["Create a caption style from a reference image",
                    "Show the name tag styles",
                    "Match the text look of this video"]

    struct Snapshot: Equatable, Sendable {
        /// A `TextLooksTab` raw value.
        var tab = "Captions"
        var captionStyles = 0
        var tagStyles = 0
        var namedStyles = 0
    }

    /// Fact key of the saved-style count each tab lists; nil for Overlays and Fonts.
    static func countKey(tab: String) -> String? {
        switch tab {
        case "Captions": "captionStyles"
        case "Name tags": "tagStyles"
        case "Named styles": "namedStyles"
        default: nil
        }
    }

    static func context(_ s: Snapshot) -> AssistantContext {
        AssistantContext(
            page: pageName, subpage: s.tab,
            facts: [AssistantFact("captionStyles", "Caption styles", s.captionStyles),
                    AssistantFact("tagStyles", "Name tag styles", s.tagStyles),
                    AssistantFact("namedStyles", "Named styles", s.namedStyles)],
            settings: [AssistantFact("tab", "Tab", s.tab)],
            summary: [AssistantText.count(s.captionStyles, "caption style"),
                      AssistantText.count(s.tagStyles, "name tag style"),
                      AssistantText.count(s.namedStyles, "named style")])
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext {
        let profile = store.activeProfile
        let tab = store.assistant.state(page).text("tab") ?? TextLooksTab.remembered().rawValue
        return Self.context(Snapshot(tab: tab, captionStyles: profile.captionStyles?.count ?? 0,
                                     tagStyles: profile.tagStyles?.count ?? 0, namedStyles: profile.textStyles?.count ?? 0))
    }

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        let total = ["captionStyles", "tagStyles", "namedStyles"].reduce(0) { $0 + (context.int($1) ?? 0) }
        if total == 0 {
            return [.init(id: "text.styles.none", kind: .action, title: "Create a style from a file",
                          reason: "Only the profile defaults so far: build one from a reference image or video",
                          actionID: "text.create")]
        }
        guard let tab = context.value("tab"), let key = Self.countKey(tab: tab), (context.int(key) ?? 0) == 0 else { return [] }
        return [.init(id: "text.\(key).none", kind: .action, title: "Create a \(tab.lowercased()) style from a file",
                      reason: "No saved \(tab.lowercased()) styles yet", actionID: "text.create")]
    }

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        var actions: [AssistantAction] = [.command("text.create", "Create from File", "wand.and.stars",
                                                   message: "Opened Create from File.")]
        for tab in TextLooksTab.allCases {
            actions.append(.command("text.tab.\(tab.id)", "Show \(tab.rawValue)", SidebarSection.text.systemImage,
                                    message: "Showing \(tab.rawValue)."))
        }
        return actions
    }

    static func route(_ text: String) -> String? {
        let t = AssistantText.normalized(text)
        if t.isEmpty { return nil }
        if AssistantText.mentions(t, ["create", "from file", "from a file", "reference", "match", "import", "make"]) {
            return "text.create"
        }
        // TextLooksTab raw values (the tab picker's titles).
        let tabs: [(String, [String])] = [("Name tags", ["name tag", "tag"]), ("Captions", ["caption"]),
                                          ("Overlays", ["overlay"]), ("Named styles", ["named"]), ("Fonts", ["font"])]
        for (tab, words) in tabs where AssistantText.mentions(t, words) { return "text.tab.\(tab)" }
        return nil
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        AssistantText.run(Self.route(text), actions: actions(store: store), store: store,
                          fallback: AssistantText.unrecognized(page: page, examples: examples))
    }
}

// MARK: - Bumpers, Images, Music (AssetBrowserView)

nonisolated struct AssetsAssistant: PageAssistant {
    let kind: AssetKind
    var page: String { kind.title }
    var examples: [String] {
        switch kind {
        case .images: ["Tag every image with AI", "Find images of the octagon", "Add images to this folder"]
        case .bumpers: ["Add an intro bumper", "Make a new folder for outros", "Show the bumpers in Finder"]
        default: ["Add background music", "Make a new folder for this show", "Show the music in Finder"]
        }
    }

    struct Snapshot: Equatable, Sendable {
        var kind: AssetKind = .images
        var files = 0
        var folders = 0
        /// Images without AI subjects and tags.
        var untagged = 0
        var tagging = 0
        var folder = ""
    }

    var prefix: String { kind.rawValue }

    static func context(_ s: Snapshot) -> AssistantContext {
        var facts = [AssistantFact("files", "Files here", s.files), AssistantFact("folders", "Folders here", s.folders)]
        if s.kind == .images {
            facts += [AssistantFact("untagged", "Untagged images", s.untagged), AssistantFact("tagging", "Tagging", s.tagging)]
        }
        var summary = [s.folder.isEmpty ? "Top folder" : s.folder, AssistantText.count(s.files, "file")]
        if s.kind == .images, s.untagged > 0 { summary.append("\(s.untagged) untagged") }
        return AssistantContext(page: s.kind.title, facts: facts, settings: [AssistantFact("folder", "Folder", s.folder)],
                                summary: summary)
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext {
        let state = store.assistant.state(page)
        return Self.context(Snapshot(kind: kind, files: state.count("files"), folders: state.count("folders"),
                                     untagged: state.count("untagged"), tagging: state.count("tagging"),
                                     folder: state.text("folder") ?? ""))
    }

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        let files = context.int("files") ?? 0
        if files == 0, (context.int("folders") ?? 0) == 0 {
            return [.init(id: "\(prefix).files.none", kind: .action, title: "Add \(page.lowercased())",
                          reason: "This folder is empty", actionID: "\(prefix).add")]
        }
        guard kind == .images else { return [] }
        let untagged = context.int("untagged") ?? 0
        if untagged > 0, (context.int("tagging") ?? 0) == 0 {
            return [.init(id: "images.tags.missing", kind: .action, title: "Tag images with AI",
                          reason: "\(AssistantText.count(untagged, "image")) here \(untagged == 1 ? "has" : "have") no subjects or B-roll mark",
                          actionID: "images.tag")]
        }
        return []
    }

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        let page = page
        var actions: [AssistantAction] = [
            .command("\(prefix).add", "Add Files", "plus", message: "Choose files to add."),
            .command("\(prefix).folder", "New Folder", "folder.badge.plus", message: "Name the new folder."),
            .command("\(prefix).finder", "Show in Finder", "folder", message: "Opened the folder in Finder."),
        ]
        if kind == .images {
            actions += [
                .command("images.tag", "Tag Images with AI", "sparkles", message: "Tagging the visible images.",
                         available: { $0.assistant.state(page).count("tagging") == 0 }),
                .command("images.ask", "Ask Images", "sparkle.magnifyingglass", message: "Opened Ask Images.",
                         available: { $0.assistant.state(page).count("files") > 0 }),
            ]
        }
        return actions
    }

    static func route(_ text: String, kind: AssetKind) -> String? {
        let t = AssistantText.normalized(text)
        if t.isEmpty { return nil }
        let prefix = kind.rawValue
        if kind == .images {
            if AssistantText.mentions(t, ["tag", "label", "subject", "b-roll", "broll"]) { return "images.tag" }
            if AssistantText.mentions(t, ["find", "search", "look for", "show me"]) { return "images.ask" }
        }
        if AssistantText.mentions(t, ["new folder", "folder for", "make a folder"]) { return "\(prefix).folder" }
        if AssistantText.mentions(t, ["finder", "reveal"]) { return "\(prefix).finder" }
        if AssistantText.mentions(t, ["add", "import", "upload"]) { return "\(prefix).add" }
        return nil
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        AssistantText.run(Self.route(text, kind: kind), actions: actions(store: store), store: store,
                          fallback: AssistantText.unrecognized(page: page, examples: examples))
    }
}
