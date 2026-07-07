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
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case library
    case scenes
    case builder
    case analyze
    case wizard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "Library"
        case .scenes: return "Scenes"
        case .builder: return "Builder"
        case .analyze: return "Analyze"
        case .wizard: return "AI Wizard"
        }
    }

    var systemImage: String {
        switch self {
        case .library: return "film.stack"
        case .scenes: return "square.grid.3x3"
        case .builder: return "timeline.selection"
        case .analyze: return "sparkles.rectangle.stack"
        case .wizard: return "wand.and.stars"
        }
    }
}

struct MainWindowView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: SidebarSection? = .library

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .library {
            case .library: LibraryView()
            case .scenes: ScenesView()
            case .builder: BuilderView()
            case .analyze: AnalyzeView()
            case .wizard: WizardView()
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
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

#Preview {
    MainWindowView()
        .environment(AppStore())
}
