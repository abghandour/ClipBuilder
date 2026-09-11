import SwiftUI

struct ProjectSidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var showingNewProject = false
    @State private var newProjectName = ""

    /// The project group's header: the current project's name with the
    /// switcher behind it, so the rows below read as "inside this project".
    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Menu {
                Section("Recent Projects") {
                    ForEach(store.projects.filter { !$0.archived }.prefix(6)) { project in
                        Button {
                            store.selectProject(project.id)
                        } label: {
                            Label(
                                project.name,
                                systemImage: project.isHome
                                    ? "house.fill"
                                    : project.id == store.activeProjectID && !store.isShowingProjectsHome
                                        ? "checkmark"
                                        : "folder"
                            )
                        }
                    }
                }
                Divider()
                Button("All Projects…", systemImage: "square.grid.2x2") {
                    store.showProjectsHome()
                }
                Button("New Project…", systemImage: "plus") {
                    newProjectName = ""
                    showingNewProject = true
                }
            } label: {
                HStack(spacing: Theme.spaceS) {
                    Image(systemName: store.activeProject?.isHome == true ? "house.fill" : "folder")
                        .foregroundStyle(Theme.projectTint)
                    Text(store.isShowingProjectsHome || store.activeProject == nil
                         ? "Choose a project…" : store.activeProject?.name ?? "Home")
                        .bold()
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .textCase(nil)
            .font(.subheadline)
        }
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: Theme.spaceS) {
            List(
                selection: Binding(
                    get: { store.isShowingProjectsHome ? nil : store.selectedSection },
                    set: { section in
                        if let section { store.selectSection(section) }
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
                        .badge(section.shortcutLabel.map { Text($0).monospaced() })
                        .tag(section)
                        .disabled(store.activeProjectID == nil)
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
                        .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)

            ProviderStatusRow()
        }
        .padding(.horizontal, Theme.spaceS)
        .padding(.top, Theme.spaceS)
        .alert("New Project", isPresented: $showingNewProject) {
            TextField("Project name", text: $newProjectName)
            Button("Create", action: createProject)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a new job inside \(store.activeProfile.profileName).")
        }
    }

    private func createProject() {
        store.createProject(named: newProjectName)
    }
}

