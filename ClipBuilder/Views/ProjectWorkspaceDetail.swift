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

    /// Every project destination stays mounted once visited: memory is spent
    /// so switching back never rebuilds the page or reruns its appear-time work.
    private static let retainedDestinations: [SidebarSection] = [
        .sources, .scenes, .wizard, .timelines, .outputs, .people, .instagram, .instagramReports,
        .screenCrops, .effects, .looks, .bumpers, .text, .images, .music
    ]

    var body: some View {
        ZStack {
            ForEach(Self.retainedDestinations, id: \.self) { section in
                if visited.contains(section) || (showsProject && destination == section) {
                    retained(section) { page(section) }
                }
            }
            otherPage
        }
        .onChange(of: destination, initial: true) { _, _ in pageChanged() }
        .onChange(of: store.isShowingProjectsHome) { _, _ in pageChanged() }
    }

    @ViewBuilder
    private func page(_ section: SidebarSection) -> some View {
        switch section {
        case .sources: AnalyzeView()
        case .scenes: ProjectScenesView()
        case .wizard: WizardHostView()
        case .timelines:
            if store.openTimelineID == nil {
                TimelinesView()
            } else {
                BuilderView()
            }
        case .outputs: LibraryView()
        case .people: PeopleView()
        case .instagram: InstagramView(tab: .posts)
        case .instagramReports: InstagramView(tab: .reports)
        case .screenCrops: ScreenCropsView()
        case .effects: TransitionsView()
        case .looks: LooksView()
        case .bumpers: AssetBrowserView(kind: .bumpers)
        case .text:
            TextLooksView(tab: TextLooksTab.tab(for: store.selectedSection) ?? TextLooksTab.remembered())
                .id(store.activeProfile.profileName)
        case .images: AssetBrowserView(kind: .images)
        case .music: AssetBrowserView(kind: .music)
        default: EmptyView()
        }
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
            if showsProject && Self.retainedDestinations.contains(section) {
                focusedPage = section
            }
            UITiming.responseReady(screen: "Sidebar", what: section.rawValue)
        }
    }

    @ViewBuilder
    private var otherPage: some View {
        if destination == .text, !store.isShowingProjectsHome, store.activeProjectID == nil {
            TextLooksView(tab: TextLooksTab.tab(for: store.selectedSection) ?? TextLooksTab.remembered())
                .id(store.activeProfile.profileName)
        } else if store.selectedSection == .learned && !store.isShowingProjectsHome {
            LearnedPreferencesView()
        } else if !showsProject {
            ProjectsHomeView()
        } else if destination == .projects {
            ProjectsHomeView()
        }
    }
}
