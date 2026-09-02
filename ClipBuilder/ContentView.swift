import SwiftUI

@main
struct ClipBuilderApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(store)
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
            // ⌘1–⌘8 section switching, routed through requestedSection —
            // the same channel views use — so the sidebar stays in sync.
            // Only the workflow sections carry numbers; asset browsers don't.
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(SidebarSection.allCases.filter { $0.shortcut != nil }) { section in
                    Button(section.title) {
                        store.requestedSection = section
                    }
                    .keyboardShortcut(section.shortcut ?? "0", modifiers: .command)
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

/// Case order follows the workflow (footage in → finished reel out). The
/// ⌘1–⌘8 shortcuts number the workflow rows in the order the sidebar
/// displays them (Footage → Create → Output, Assets unnumbered), and each
/// row shows its shortcut so the mapping is learnable from the screen.
enum SidebarSection: String, CaseIterable, Identifiable {
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

    /// Source > Videos: footage in, scene detection.
    static let videoSections: [SidebarSection] = [.analyze, .scenes, .curated, .people]
    /// Instagram: the reels browser and the analytics reports.
    static let instagramSections: [SidebarSection] = [.instagram, .instagramReports]
    /// Source asset libraries: media browsers plus overlay templates.
    static let assetSections: [SidebarSection] = [.music, .fonts, .images, .overlays, .effects, .screenCrops]
    static let createSections: [SidebarSection] = [.wizard, .builder]
    static let outputSections: [SidebarSection] = [.library]

    /// ⌘1–⌘9 matching the sidebar's visible top-to-bottom workflow order
    /// (Footage, Create, Output, Instagram). Asset browsers have no number.
    private var shortcutDigit: Character? {
        switch self {
        case .analyze: return "1"
        case .scenes: return "2"
        case .curated: return "3"
        case .people: return "4"
        case .wizard: return "5"
        case .builder: return "6"
        case .library: return "7"
        case .instagram: return "8"
        case .instagramReports: return "9"
        case .music, .fonts, .images, .overlays, .effects, .screenCrops: return nil
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
        case .library: return "Library"
        case .scenes: return "Raw Scenes"
        case .curated: return "Curated Scenes"
        case .people: return "People"
        case .builder: return "Builder"
        case .analyze: return "Raw Videos"
        case .wizard: return "AI Wizard"
        case .instagram: return "Posts"
        case .instagramReports: return "Reports"
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
        case .library: return "film.stack"
        case .scenes: return "square.grid.3x3"
        case .curated: return "checkmark.seal"
        case .people: return "person.2"
        case .builder: return "timeline.selection"
        case .analyze: return "sparkles.rectangle.stack"
        case .wizard: return "wand.and.stars"
        case .instagram: return "play.rectangle.on.rectangle"
        case .instagramReports: return "chart.bar.xaxis"
        case .music: return AssetKind.music.systemImage
        case .fonts: return AssetKind.fonts.systemImage
        case .images: return AssetKind.images.systemImage
        case .overlays: return "character.textbox"
        case .effects: return "sparkles.tv"
        case .screenCrops: return "crop"
        }
    }
}

struct MainWindowView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: SidebarSection? = .analyze

    // Each sidebar group's disclosure state survives relaunches.
    @AppStorage("sidebar.expanded.assets") private var assetsExpanded = true
    @AppStorage("sidebar.expanded.footage") private var footageExpanded = true
    @AppStorage("sidebar.expanded.instagram") private var instagramExpanded = true
    @AppStorage("sidebar.expanded.create") private var createExpanded = true
    @AppStorage("sidebar.expanded.output") private var outputExpanded = true

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $selection) {
                Section("Assets", isExpanded: $assetsExpanded) {
                    sidebarItems(SidebarSection.assetSections, tint: Theme.assetsTint)
                }
                Section("Footage", isExpanded: $footageExpanded) {
                    sidebarItems(SidebarSection.videoSections, tint: Theme.footageTint)
                }
                Section("Create", isExpanded: $createExpanded) {
                    sidebarItems(SidebarSection.createSections, tint: Theme.createTint)
                }
                Section("Output", isExpanded: $outputExpanded) {
                    sidebarItems(SidebarSection.outputSections, tint: Theme.outputTint)
                }
                Section("Instagram", isExpanded: $instagramExpanded) {
                    sidebarItems(SidebarSection.instagramSections, tint: Theme.instagramTint)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .analyze {
            case .library: LibraryView()
            case .scenes: ScenesView()
            case .curated: CuratedView()
            case .people: PeopleView()
            case .builder: BuilderView()
            case .analyze: AnalyzeView()
            case .wizard: WizardView()
            case .instagram: InstagramView(tab: .posts)
            case .instagramReports: InstagramView(tab: .reports)
            case .music: AssetBrowserView(kind: .music)
            case .fonts: AssetBrowserView(kind: .fonts)
            case .images: AssetBrowserView(kind: .images)
            case .overlays: OverlayTemplatesView()
            case .effects: EffectsView()
            case .screenCrops: ScreenCropsView()
            }
        }
        .onChange(of: store.requestedSection) { _, requested in
            if let requested {
                selection = requested
                store.requestedSection = nil
            }
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
        .navigationTitle("Clip Builder")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Profile", selection: Binding(
                    get: { store.activeProfile.profileName },
                    set: { store.switchProfile(named: $0) }
                )) {
                    ForEach(store.profiles) { profile in
                        Text(profile.profileName).tag(profile.profileName)
                    }
                }
                .pickerStyle(.menu)
                .help("Active brand profile")
            }
        }
        // Results first; a queued A/B comparison presents after it closes.
        .sheet(item: $store.wizardResults) { results in
            WizardResultsSheet(results: results)
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
    }

    /// Rows for one sidebar group: tinted icon (one hue per group, Mail
    /// style), the visible ⌘-shortcut so the mapping is learnable on sight.
    private func sidebarItems(_ sections: [SidebarSection], tint: Color) -> some View {
        ForEach(sections) { section in
            Label {
                Text(section.title)
            } icon: {
                Image(systemName: section.systemImage)
                    .foregroundStyle(tint)
            }
            .badge(section.shortcutLabel.map { Text($0).monospaced() })
            .tag(section)
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
