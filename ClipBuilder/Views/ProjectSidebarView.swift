import SwiftUI

struct ProjectSidebarView: View {
    @Environment(AppStore.self) private var store
    /// The project group's header: the current project's name, so the rows
    /// below read as "inside this project". One click opens All Projects,
    /// where projects are switched and created.
    private var projectHeader: some View {
        Button {
            store.showProjectsHome()
        } label: {
            // Same Label, icon and body font as the rows below, so the
            // project reads as the parent of those rows, not as a section
            // caption.
            Label {
                Text(store.isShowingProjectsHome || store.activeProject == nil
                     ? "Choose a project…" : store.activeProject?.name ?? "Home")
                    .bold()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                Image(systemName: store.activeProject?.isHome == true ? "house.fill" : "folder")
                    .foregroundStyle(Theme.projectTint)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .textCase(nil)
        .font(.body)
        // Room between the project's name and the selected row's highlight.
        .padding(.bottom, Theme.spaceS)
        .help("Show all projects")
        .accessibilityHint("Shows all projects")
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: Theme.spaceS) {
            List(
                selection: Binding(
                    get: { store.isShowingProjectsHome ? nil : store.selectedSection },
                    set: { section in
                        if let section {
                            if store.isShowingProjectsHome || section.projectDestination != store.selectedSection.projectDestination {
                                UITiming.sectionChanged(to: section.projectDestination.rawValue)
                            }
                            store.selectSection(section)
                        }
                    }
                )
            ) {
                Section {
                    ForEach(SidebarSection.projectSections) { section in
                        Label {
                            Text(section.title)
                        } icon: {
                            Image(systemName: section.systemImage)
                                .foregroundStyle(section.tint)
                        }
                        .padding(.leading, Theme.sidebarRowIndent)
                        .badge(section.shortcutLabel.map { Text($0).monospaced() })
                        .tag(section)
                        .disabled(store.activeProjectID == nil)
                        .help(section.help)
                    }
                } header: {
                    projectHeader
                }

                Section("Instagram") {
                    ForEach(SidebarSection.studioSections) { section in
                        Label {
                            Text(section.title)
                        } icon: {
                            Image(systemName: section.systemImage)
                                .foregroundStyle(section.tint)
                        }
                        .padding(.leading, Theme.sidebarRowIndent)
                        .badge(section.shortcutLabel.map { Text($0).monospaced() })
                        .tag(section)
                    }
                }

                Section("Resources") {
                    ForEach(SidebarSection.resourceSections) { section in
                        Label {
                            Text(section.title)
                        } icon: {
                            Image(systemName: section.systemImage)
                                .foregroundStyle(section.tint)
                        }
                        .padding(.leading, Theme.sidebarRowIndent)
                        .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .padding(.horizontal, Theme.spaceS)
        .padding(.top, Theme.spaceS)
    }
}
