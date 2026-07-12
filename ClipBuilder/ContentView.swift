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
            CommandGroup(after: .newItem) {
                Button("Scan Input Folder") {
                    store.scanSourceFolder()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            // ⌘1–⌘6 section switching, routed through requestedSection —
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
/// drives the sidebar order and the ⌘1–⌘6 shortcuts.
enum SidebarSection: String, CaseIterable, Identifiable {
    case analyze
    case scenes
    case instagram
    case wizard
    case builder
    case library

    var id: String { rawValue }

    /// Sidebar groups: what feeds creation (footage and reference templates),
    /// where reels are made, and where they end up.
    static let groups: [(title: String, sections: [SidebarSection])] = [
        ("Source", [.analyze, .scenes, .instagram]),
        ("Create", [.wizard, .builder]),
        ("Output", [.library]),
    ]

    /// ⌘1–⌘6, in workflow order.
    var shortcut: KeyEquivalent? {
        guard let index = Self.allCases.firstIndex(of: self),
              let digit = "\(index + 1)".first else { return nil }
        return KeyEquivalent(digit)
    }

    var title: String {
        switch self {
        case .library: return "Library"
        case .scenes: return "Scenes"
        case .builder: return "Builder"
        case .analyze: return "Analyze"
        case .wizard: return "AI Wizard"
        case .instagram: return "Instagram"
        }
    }

    var systemImage: String {
        switch self {
        case .library: return "film.stack"
        case .scenes: return "square.grid.3x3"
        case .builder: return "timeline.selection"
        case .analyze: return "sparkles.rectangle.stack"
        case .wizard: return "wand.and.stars"
        case .instagram: return "play.rectangle.on.rectangle"
        }
    }
}

struct MainWindowView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: SidebarSection? = .analyze

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarSection.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            Label(section.title, systemImage: section.systemImage)
                                .tag(section)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .analyze {
            case .library: LibraryView()
            case .scenes: ScenesView()
            case .builder: BuilderView()
            case .analyze: AnalyzeView()
            case .wizard: WizardView()
            case .instagram: InstagramView()
            }
        }
        .onChange(of: store.requestedSection) { _, requested in
            if let requested {
                selection = requested
                store.requestedSection = nil
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
        .alert("Error", isPresented: Binding(
            get: { store.currentError != nil },
            set: { if !$0 { store.dismissCurrentError() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.currentError?.message ?? "")
        }
    }
}

#Preview {
    MainWindowView()
        .environment(AppStore())
}
