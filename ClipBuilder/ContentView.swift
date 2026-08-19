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
            // ⌘1–⌘9 section switching, routed through requestedSection —
            // the same channel views use — so the sidebar stays in sync.
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(SidebarSection.allCases) { section in
                    Button(section.title) {
                        store.requestedSection = section
                    }
                    .keyboardShortcut(section.shortcut ?? "0", modifiers: .command)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

/// Case order follows the workflow (footage in → finished reel out); it also
/// drives the sidebar order and the ⌘1–⌘9 shortcuts.
enum SidebarSection: String, CaseIterable, Identifiable {
    case analyze
    case scenes
    case people
    case instagram
    case music
    case fonts
    case images
    case overlays
    case wizard
    case builder
    case library

    var id: String { rawValue }

    /// Source > Videos: footage in, scene detection, reference reels.
    static let videoSections: [SidebarSection] = [.analyze, .scenes, .people, .instagram]
    /// Source asset libraries: media browsers plus overlay templates.
    static let assetSections: [SidebarSection] = [.music, .fonts, .images, .overlays]
    static let createSections: [SidebarSection] = [.wizard, .builder]
    static let outputSections: [SidebarSection] = [.library]

    /// ⌘1–⌘9 in workflow order; the tenth section wraps to ⌘0.
    var shortcut: KeyEquivalent? {
        guard let index = Self.allCases.firstIndex(of: self), index < 10,
              let digit = "\((index + 1) % 10)".first else { return nil }
        return KeyEquivalent(digit)
    }

    var title: String {
        switch self {
        case .library: return "Library"
        case .scenes: return "Scenes"
        case .people: return "People"
        case .builder: return "Builder"
        case .analyze: return "Analyze"
        case .wizard: return "AI Wizard"
        case .instagram: return "Instagram"
        case .music: return AssetKind.music.title
        case .fonts: return AssetKind.fonts.title
        case .images: return AssetKind.images.title
        case .overlays: return "Overlays"
        }
    }

    var systemImage: String {
        switch self {
        case .library: return "film.stack"
        case .scenes: return "square.grid.3x3"
        case .people: return "person.2"
        case .builder: return "timeline.selection"
        case .analyze: return "sparkles.rectangle.stack"
        case .wizard: return "wand.and.stars"
        case .instagram: return "play.rectangle.on.rectangle"
        case .music: return AssetKind.music.systemImage
        case .fonts: return AssetKind.fonts.systemImage
        case .images: return AssetKind.images.systemImage
        case .overlays: return "character.textbox"
        }
    }
}

struct MainWindowView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: SidebarSection? = .analyze
    @State private var videosExpanded = true

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $selection) {
                Section("Source") {
                    DisclosureGroup(isExpanded: $videosExpanded) {
                        sidebarItems(SidebarSection.videoSections)
                    } label: {
                        Label("Videos", systemImage: "video")
                    }
                    sidebarItems(SidebarSection.assetSections)
                }
                Section("Create") {
                    sidebarItems(SidebarSection.createSections)
                }
                Section("Output") {
                    sidebarItems(SidebarSection.outputSections)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .analyze {
            case .library: LibraryView()
            case .scenes: ScenesView()
            case .people: PeopleView()
            case .builder: BuilderView()
            case .analyze: AnalyzeView()
            case .wizard: WizardView()
            case .instagram: InstagramView()
            case .music: AssetBrowserView(kind: .music)
            case .fonts: AssetBrowserView(kind: .fonts)
            case .images: AssetBrowserView(kind: .images)
            case .overlays: OverlayTemplatesView()
            }
        }
        .onChange(of: store.requestedSection) { _, requested in
            if let requested {
                selection = requested
                store.requestedSection = nil
            }
        }
        // ⌘-shortcut or programmatic jumps into a Videos section must reveal
        // the row even when the disclosure group is collapsed.
        .onChange(of: selection) { _, selected in
            if let selected, SidebarSection.videoSections.contains(selected) {
                videosExpanded = true
            }
        }
        .navigationTitle("ClipBuilder")
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
        .alert("Error", isPresented: Binding(
            get: { store.currentError != nil },
            set: { if !$0 { store.dismissCurrentError() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.currentError?.message ?? "")
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
            AssetStore.ensureRoots()
            AssetStore.registerFonts()
        }
    }

    /// Rows for one sidebar group.
    private func sidebarItems(_ sections: [SidebarSection]) -> some View {
        ForEach(sections) { section in
            Label(section.title, systemImage: section.systemImage)
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
