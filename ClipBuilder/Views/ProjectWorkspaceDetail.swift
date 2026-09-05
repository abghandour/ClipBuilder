import SwiftUI

struct ProjectWorkspaceDetail: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.isShowingProjectsHome || store.activeProjectID == nil {
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
                    WizardView()
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
                case .fonts:
                    AssetBrowserView(kind: .fonts)
                case .images:
                    AssetBrowserView(kind: .images)
                case .overlays:
                    OverlayTemplatesView()
                case .effects:
                    EffectsView()
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
