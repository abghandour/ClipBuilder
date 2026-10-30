import SwiftUI

struct ProjectWorkspaceDetail: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ProjectWorkspacePages()
            // Retain pages within this workspace, never across projects or profiles.
            .id("\(store.profileGeneration):\(store.activeProjectID ?? -1)")
    }
}

private struct ProjectWorkspacePages: View {
    @Environment(AppStore.self) private var store
    @State private var visited: Set<SidebarSection> = []
    @FocusState private var focusedPage: SidebarSection?

    private var destination: SidebarSection { store.selectedSection.projectDestination }
    private var showsProject: Bool { !store.isShowingProjectsHome && store.activeProjectID != nil }

    var body: some View {
        ZStack {
            if visited.contains(.sources) || (showsProject && destination == .sources) {
                retained(.sources) { AnalyzeView() }
            }
            if visited.contains(.scenes) || (showsProject && destination == .scenes) {
                retained(.scenes) { ProjectScenesView() }
            }
            if visited.contains(.outputs) || (showsProject && destination == .outputs) {
                retained(.outputs) { LibraryView() }
            }
            otherPage
        }
        .onChange(of: destination, initial: true) { _, _ in pageChanged() }
        .onChange(of: store.isShowingProjectsHome) { _, _ in pageChanged() }
    }

    private func retained<Content: View>(_ section: SidebarSection,
                                         @ViewBuilder content: () -> Content) -> some View {
        let visible = showsProject && destination == section
        return content()
            .environment(\.workspacePageVisible, visible)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .disabled(!visible)
            .accessibilityHidden(!visible)
            .focusable(visible)
            .focusEffectDisabled()
            .focused($focusedPage, equals: section)
            .focusSection()
    }

    private func pageChanged() {
        let section = destination
        let projectID = store.activeProjectID
        let generation = store.profileGeneration
        if showsProject { visited.insert(section) }
        focusedPage = nil
        // Let visibility and the destination's layout update before closing the signpost.
        DispatchQueue.main.async {
            guard destination == section, store.activeProjectID == projectID,
                  store.profileGeneration == generation else { return }
            if showsProject && [.sources, .scenes, .outputs].contains(section) {
                focusedPage = section
            }
            UITiming.responseReady(screen: "Sidebar", what: section.rawValue)
        }
    }

    @ViewBuilder
    private var otherPage: some View {
        if destination == .text, !store.isShowingProjectsHome {
            TextLooksView(tab: TextLooksTab.tab(for: store.selectedSection) ?? TextLooksTab.remembered())
                .id(store.activeProfile.profileName)
        } else if store.selectedSection == .learned && !store.isShowingProjectsHome {
            LearnedPreferencesView()
        } else if !showsProject {
            ProjectsHomeView()
        } else {
            switch store.selectedSection.projectDestination {
            case .sources, .scenes, .outputs:
                EmptyView()
            case .timelines:
                if store.openTimelineID == nil {
                    TimelinesView()
                } else {
                    BuilderView()
                }
            case .wizard:
                WizardHostView()
            case .people:
                PeopleView()
            case .instagram:
                InstagramView(tab: .posts)
            case .instagramReports:
                InstagramView(tab: .reports)
            case .music:
                AssetBrowserView(kind: .music)
            case .images:
                AssetBrowserView(kind: .images)
            case .text, .tags, .captions, .overlays, .fonts:
                TextLooksView(tab: TextLooksTab.tab(for: store.selectedSection) ?? TextLooksTab.remembered())
                    .id(store.activeProfile.profileName)
            case .effects:
                TransitionsView()
            case .looks:
                LooksView()
            case .bumpers:
                AssetBrowserView(kind: .bumpers)
            case .screenCrops:
                ScreenCropsView()
            case .projects:
                ProjectsHomeView()
            default:
                EmptyView()
            }
        }
    }
}
