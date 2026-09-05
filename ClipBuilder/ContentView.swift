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
        guard let store else { return .terminateNow }
        Task { @MainActor in
            await store.flushForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ClipBuilderApp: App {
    @State private var store = AppStore()
    @NSApplicationDelegateAdaptor(TerminationDelegate.self) private var terminationDelegate

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(store)
                .onAppear { terminationDelegate.store = store }
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
                    Button(section.title) {
                        store.requestedSection = section
                    }
                    .keyboardShortcut(section.shortcut ?? "0", modifiers: .command)
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
    case screenCrops
    case wizard
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
    static let resourceSections: [SidebarSection] = [.music, .fonts, .images, .overlays, .effects, .screenCrops]
    static let visibleSections = projectSections + studioSections + resourceSections

    /// ⌘1–⌘8 matching the visible sidebar's top-to-bottom order.
    private var shortcutDigit: Character? {
        switch self {
        case .sources: return "1"
        case .scenes: return "2"
        case .wizard: return "3"
        case .timelines: return "4"
        case .outputs: return "5"
        case .people: return "6"
        case .instagram: return "7"
        case .instagramReports: return "8"
        case .projects, .analyze, .curated, .builder, .library, .resources,
             .music, .fonts, .images, .overlays, .effects, .screenCrops: return nil
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
        case .wizard: return "AI Wizard"
        case .instagram: return "Posts"
        case .instagramReports: return "Reports"
        case .resources: return "Resources"
        case .music: return AssetKind.music.title
        case .fonts: return AssetKind.fonts.title
        case .images: return AssetKind.images.title
        case .overlays: return "Overlays"
        case .effects: return "Effects"
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
        case .wizard: return "wand.and.stars"
        case .instagram: return "camera"
        case .instagramReports: return "chart.bar.xaxis"
        case .resources: return "line.3.horizontal"
        case .music: return AssetKind.music.systemImage
        case .fonts: return AssetKind.fonts.systemImage
        case .images: return AssetKind.images.systemImage
        case .overlays: return "character.textbox"
        case .effects: return "sparkles.tv"
        case .screenCrops: return "crop"
        }
    }

    var projectDestination: SidebarSection {
        switch self {
        case .projects: .projects
        case .sources, .analyze: .sources
        case .scenes, .curated: .scenes
        case .timelines, .builder: .timelines
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
        case .screenCrops: .screenCrops
        }
    }
}

struct MainWindowView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            ProjectSidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 290)
        } detail: {
            ProjectWorkspaceDetail()
        }
        .onChange(of: store.requestedSection) { _, requested in
            handleRequestedSection(requested)
        }
        // The Analyze Wizard's fire-and-forget progress: a window-wide strip
        // that follows the user across screens; click for the full log.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PipelineStatusInset()
        }
        .sheet(isPresented: $store.showPipelineLog) {
            PipelineLogSheet()
        }
        // Instagram refresh / history import: the same bottom-strip pattern.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            InstagramStatusInset()
        }
        .sheet(isPresented: $store.showIGLog) {
            InstagramLogSheet()
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
        )) {
            Button("OK", role: .cancel) {}
            Button("Copy Details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.currentError?.message ?? "",
                                               forType: .string)
            }
        } message: {
            Text(store.currentError?.message ?? "")
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

/// The pipeline strip's presence check, in its own view so stage/progress
/// writes re-evaluate this leaf instead of the whole main window.
private struct PipelineStatusInset: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.isPipelineRunning || !store.pipelineStage.isEmpty {
            VStack(spacing: 0) {
                Divider()
                PipelineStatusBar()
            }
        }
    }
}

/// Same for the Instagram refresh/import strip, which updates per progress line.
private struct InstagramStatusInset: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.igStatus != nil {
            VStack(spacing: 0) {
                Divider()
                InstagramStatusBar()
            }
        }
    }
}
