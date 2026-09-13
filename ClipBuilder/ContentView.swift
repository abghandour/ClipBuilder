import BugReporterKit
import SwiftUI

// THESIS: Project scope is the app's primary orientation; the old twelve-screen global sidebar is retired.
// OWN-WORLD: Native macOS split navigation, compact graphite surfaces, semantic color, and media-led rows.
// STORY: Pick a profile, enter one project, then move from sources through scenes and timelines to outputs.
// FIRST VIEWPORT: Profile and project switchers anchor the sidebar; the active project's working surface fills detail.
// FORM: User-pinned project workspace from docs/ui-projects/README.md; no generated seed applies.
// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

/// Cmd-Q: hold termination until the open timeline and project state are
/// in the database. The debounced autosave and the fire-and-forget state
/// writes would otherwise be lost with the process.
final class TerminationDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, !store.hasFlushedForTermination else {
            BugReporter.markCleanExit()
            return .terminateNow
        }
        // Deferring only works when `terminate` was reached from the event
        // loop (Cmd-Q). A caller inside a main-queue callout must flush first
        // and set `hasFlushedForTermination`, or the nested run loop below
        // never runs this task and the app hangs.
        Task { @MainActor in
            await store.flushForTermination()
            BugReporter.markCleanExit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ClipBuilderApp: App {
    @State private var store: AppStore
    @NSApplicationDelegateAdaptor(TerminationDelegate.self) private var terminationDelegate

    init() {
        let store = AppStore()
        BugReporting.configureIfPossible(store: store)
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            if BugReporting.isTestHost {
                // The unit-test host only needs a process; the full window
                // tree has crashed under the test runner (SwiftUI executor
                // checks during hit-testing and alert bindings) and every
                // such crash is offered to the user as a real app crash.
                Text("Clip Builder test host").padding()
            } else {
                MainWindowView()
                    .environment(store)
                    .onAppear { terminationDelegate.store = store }
            }
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            // .appInfo placement silently drops the item on this macOS, so
            // the updater lives below Settings… in the app menu instead.
            CommandGroup(after: .appSettings) {
                Button("Check for Updates…") {
                    store.checkForUpdates()
                }
                .disabled(store.isDownloadingUpdate)
            }
            CommandGroup(after: .newItem) {
                Button("Scan Input Folder") {
                    store.scanSourceFolder()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .importExport) {
                Button("Import Resources…") {
                    store.chooseResourceBundleToImport()
                }
                Button("Export Resources…") {
                    store.showResourceExport = true
                }
            }
            // Project-centered navigation: scoped production screens followed by
            // three profile-wide Studio screens.
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(SidebarSection.visibleSections) { section in
                    if let shortcut = section.shortcut {
                        Button(section.title) { store.requestedSection = section }
                            .keyboardShortcut(shortcut, modifiers: .command)
                    } else {
                        Button(section.title) { store.requestedSection = section }
                    }
                }
                Divider()
                Button("Switch Project…") { store.showProjectsHome() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Previous Project") { store.cycleProject(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Next Project") { store.cycleProject(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Divider()
                Button("Previous Timeline") { store.cycleTimeline(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                    .disabled(store.openTimelineID == nil)
                Button("Next Timeline") { store.cycleTimeline(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                    .disabled(store.openTimelineID == nil)
            }
            if BugReporting.isConfigured {
                BugReporterCommands()
            } else {
                CommandGroup(replacing: .help) {
                    Button("Report a Bug…") { BugReporting.presentReport() }
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                    Button("My Reports…") { MyReportsWindowPresenter.show() }
                }
            }
            CommandGroup(before: .help) {
                Button("Training Guide") {
                    store.showTrainingGuide = true
                }
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

/// The visible project and Studio destinations use a compact ⌘1–⌘8 order.
/// Legacy cases remain as internal routing aliases so existing
/// handoffs can open their new consolidated destination.
enum SidebarSection: String, CaseIterable, Identifiable {
    case projects
    case sources
    case timelines
    case outputs
    case resources
    case analyze
    case scenes
    case curated
    case people
    case music
    case fonts
    case images
    case overlays
    case effects
    case looks
    case screenCrops
    case bumpers
    case wizard
    case learned
    case builder
    case library
    case instagram          // Instagram → Posts (raw value kept for handoffs)
    case instagramReports

    var id: String { rawValue }

    /// People sit with the project: a project's People screen shows only
    /// people with footage in it (identities stay profile-wide).
    static let projectSections: [SidebarSection] = [.sources, .scenes, .wizard, .timelines, .outputs, .people]
    static let studioSections: [SidebarSection] = [.instagram, .instagramReports]
    /// Every resource library is its own row: one click, one screen, as the
    /// app always had it — a tab strip inside one screen hid them.
    /// AI Lessons sits with the resources: like them it is profile-wide and
    /// syncs with the Drive home (up when a nickname is set, down always).
    static let resourceSections: [SidebarSection] = [
        .music, .fonts, .images, .overlays, .effects, .looks, .screenCrops, .bumpers, .learned,
    ]
    static let visibleSections = projectSections + studioSections + resourceSections

    /// Project/studio shortcuts use ⌘1–⌘8; Bumpers uses the remaining ⌘9.
    private var shortcutDigit: Character? {
        switch self {
        case .bumpers: return "9"
        case .sources: return "1"
        case .scenes: return "2"
        case .wizard: return "3"
        case .timelines: return "4"
        case .outputs: return "5"
        case .people: return "6"
        case .instagram: return "7"
        case .instagramReports: return "8"
        case .projects, .analyze, .curated, .builder, .library, .resources, .learned,
             .music, .fonts, .images, .overlays, .effects, .looks, .screenCrops: return nil
        }
    }

    var shortcut: KeyEquivalent? {
        shortcutDigit.map { KeyEquivalent($0) }
    }

    /// "⌘1"-style badge for the sidebar row.
    var shortcutLabel: String? {
        shortcutDigit.map { "⌘\($0)" }
    }

    var title: String {
        switch self {
        case .projects: return "All Projects"
        case .sources, .analyze: return "Sources"
        case .scenes: return "Scenes"
        case .curated: return "Curated Scenes"
        case .people: return "People"
        case .timelines, .builder: return "Timelines"
        case .outputs, .library: return "Outputs"
        case .learned: return "AI Lessons"
        case .wizard: return "AI Wizard"
        case .instagram: return "Posts"
        case .instagramReports: return "Reports"
        case .resources: return "Resources"
        case .music: return AssetKind.music.title
        case .fonts: return AssetKind.fonts.title
        case .images: return AssetKind.images.title
        case .overlays: return "Overlays"
        case .effects: return "Transitions"
        case .looks: return "Looks"
        case .bumpers: return "Bumpers"
        case .screenCrops: return "Screen Crop"
        }
    }

    var systemImage: String {
        switch self {
        case .projects: return "square.grid.2x2"
        case .sources, .analyze: return "film"
        case .scenes: return "square.grid.3x3"
        case .curated: return "checkmark.seal"
        case .people: return "person.2"
        case .timelines, .builder: return "timeline.selection"
        case .outputs, .library: return "play.rectangle"
        case .learned: return "graduationcap"
        case .wizard: return "wand.and.stars"
        case .instagram: return "camera"
        case .instagramReports: return "chart.bar.xaxis"
        case .resources: return "line.3.horizontal"
        case .music: return AssetKind.music.systemImage
        case .fonts: return AssetKind.fonts.systemImage
        case .images: return AssetKind.images.systemImage
        case .overlays: return "character.textbox"
        case .effects: return "rectangle.on.rectangle"
        case .looks: return "camera.filters"
        case .bumpers: return "film.stack"
        case .screenCrops: return "crop"
        }
    }

    var projectDestination: SidebarSection {
        switch self {
        case .projects: .projects
        case .sources, .analyze: .sources
        case .scenes, .curated: .scenes
        case .timelines, .builder: .timelines
        case .learned: .learned
        case .wizard: .wizard
        case .outputs, .library: .outputs
        case .people: .people
        case .instagram: .instagram
        case .instagramReports: .instagramReports
        case .resources, .music: .music
        case .fonts: .fonts
        case .images: .images
        case .overlays: .overlays
        case .effects: .effects
        case .looks: .looks
        case .bumpers: .bumpers
        case .screenCrops: .screenCrops
        }
    }
}

struct MainWindowView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("qa.toolbarButton") private var showsQAButton = false
    @AppStorage(SettingsStore.dataFolderDefaultsKey) private var dataFolder = ""
    @State private var appeared = false
    @State private var checkedForCrashes = false

    var body: some View {
        @Bindable var store = store
        // The status bar is part of the layout, never an inset: split-view
        // panes ignore safe-area insets and were painting under it.
        VStack(spacing: 0) {
            workspace
            AppStatusBar()
        }
    }

    private var workspace: some View {
        @Bindable var store = store
        return NavigationSplitView {
            ProjectSidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 290)
        } detail: {
            ProjectWorkspaceDetail()
        }
        .bugReporterCrashPrompt()
        .onAppear {
            // AppStore.init already loads the library; do not refresh again here.
            guard !appeared else { return }
            appeared = true
            checkForCrashesWhenReady()
        }
        .onChange(of: store.currentError) { _, error in
            if error == nil { checkForCrashesWhenReady() }
        }
        .onChange(of: dataFolder) {
            store.diagnosticsDataFolder = BugReporting.homeRelative(SettingsStore.dataDirectory)
        }
        .onChange(of: store.requestedSection) { _, requested in
            handleRequestedSection(requested)
        }
        // Results first; a queued A/B comparison presents after it closes.
        .sheet(item: $store.wizardResults) { results in
            WizardResultsSheet(results: results)
        }
        .sheet(item: $store.pendingCutReview) { request in
            ProposedCutsSheet(request: request)
        }
        .sheet(item: $store.pendingComparison) { batch in
            ComparisonSheet(batch: batch)
        }
        .sheet(item: $store.pendingPeopleReview) { request in
            PersonReviewSheet(request: request)
        }
        // Presents after the people review closes when both are pending.
        .sheet(item: $store.pendingRenameReview) { request in
            RenameReviewSheet(request: request)
        }
        .alert("Error", isPresented: Binding(
            get: { store.currentError != nil },
            set: { if !$0 { store.dismissCurrentError() } }
        ), presenting: store.currentError) { error in
            Button("OK", role: .cancel) {}
            if let provider = error.signInProvider {
                Button("Sign In to \(AICatalog.provider(provider)?.label ?? provider)…") {
                    store.openProviderSignIn(provider)
                }
            }
            Button("Copy Details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(error.message, forType: .string)
            }
            Button("Report…") {
                BugReporting.presentReport(title: error.context, details: error.details)
            }
        } message: { error in
            Text(error.message)
        }
        .sheet(isPresented: $store.showTrainingGuide) {
            HelpSheet()
        }
        .sheet(isPresented: $store.showResourceExport) {
            ResourceExportSheet()
        }
        .sheet(isPresented: Binding(
            get: { store.resourceImportURL != nil },
            set: { if !$0 { store.resourceImportURL = nil } })) {
            if let url = store.resourceImportURL {
                ResourceImportSheet(zipURL: url)
            }
        }
        .alert(updateAlertTitle, isPresented: Binding(
            get: { store.updateCheckResult != nil },
            set: { if !$0 { store.updateCheckResult = nil } }
        ), presenting: store.updateCheckResult) { result in
            switch result {
            case .updateAvailable(let update):
                Button("Download and Install") {
                    store.installUpdate(update)
                }
                Button("Later", role: .cancel) {}
            case .upToDate:
                Button("OK", role: .cancel) {}
            }
        } message: { result in
            switch result {
            case .updateAvailable(let update):
                Text(Self.updateMessage(for: update))
            case .upToDate:
                Text("Clip Builder \(UpdateService.currentVersion) is the latest version.")
            }
        }
        .overlay {
            if store.isDownloadingUpdate {
                ProgressView("Downloading update…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if store.isInstallingTools {
                ProgressView("Installing video tools…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task {
            store.checkForUpdatesAtLaunch()
            store.ensureToolsAtLaunch()
            // Directory creation plus a recursive font-library walk and
            // CoreText registration: off the main thread at launch.
            await Task.detached(priority: .utility) {
                AssetStore.ensureRoots()
                AssetStore.registerFonts()
            }.value
        }
        .onDisappear {
            store.builder.flushPendingAutosave()
            store.flushActiveProjectState()
        }
        // Rightmost control on every screen: a trailing title-bar accessory,
        // not a toolbar item (root toolbar items sort before a screen's own).
        .background(QATitlebarAccessoryInstaller(
            visible: BugReporting.qaButtonVisible(preference: showsQAButton, isDebug: BugReporting.isDebugBuild)))
    }

    private func checkForCrashesWhenReady() {
        guard appeared, !checkedForCrashes, store.currentError == nil,
              BugReporting.isConfigured, !BugReporting.isTestHost else { return }
        checkedForCrashes = true
        BugReporter.checkForCrashesAndPrompt()
    }

    private func handleRequestedSection(_ requested: SidebarSection?) {
        guard let requested else { return }
        store.requestedSection = nil
        if requested == .projects {
            store.showProjectsHome()
        } else {
            if requested == .curated { store.sceneMode = "curated" }
            if requested == .scenes { store.sceneMode = "all" }
            store.selectSection(requested)
        }
    }

    private var updateAlertTitle: String {
        if case .updateAvailable = store.updateCheckResult {
            return "Update Available"
        }
        return "You're up to date"
    }

    /// Version line plus the release notes, kept short enough for an alert.
    private static func updateMessage(for update: AppUpdate) -> String {
        var message = "\(update.releaseName) is available — you have \(UpdateService.currentVersion). "
            + "The download opens in Installer; Clip Builder quits so it can update in place."
        let notes = update.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            message += "\n\n\(notes.prefix(400))"
        }
        return message
    }
}

#Preview {
    MainWindowView()
        .environment(AppStore())
}
