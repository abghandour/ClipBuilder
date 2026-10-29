import SwiftUI

struct ProjectWorkspaceDetail: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.selectedSection.projectDestination == .text, !store.isShowingProjectsHome {
                TextLooksView(tab: TextLooksTab.tab(for: store.selectedSection) ?? TextLooksTab.remembered())
                    .id(store.activeProfile.profileName)
            } else if store.selectedSection == .learned && !store.isShowingProjectsHome {
                LearnedPreferencesView()
            } else if store.isShowingProjectsHome || store.activeProjectID == nil {
                ProjectsHomeView()
            } else {
                switch store.selectedSection.projectDestination {
                case .sources:
                    AnalyzeView()
                case .scenes:
                    ProjectScenesView()
                case .timelines:
                    if store.openTimelineID == nil {
                        TimelinesView()
                    } else {
                        BuilderView()
                    }
                case .wizard:
                    WizardHostView()
                case .outputs:
                    LibraryView()
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
                    AnalyzeView()
                }
            }
        }
    }
}
