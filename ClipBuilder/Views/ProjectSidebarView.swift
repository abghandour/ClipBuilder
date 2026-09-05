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

            ProjectActivitySummary()
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

private struct ProjectActivitySummary: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXS) {
            HStack(spacing: Theme.spaceS) {
                Image(systemName: activities.isEmpty ? "chevron.right" : "chevron.down")
                    .foregroundStyle(.secondary)
                Text("Activity")
                Spacer(minLength: 0)
            }

            if activities.isEmpty {
                Text("Idle")
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 18)
            } else {
                ForEach(activities) { activity in
                    HStack(spacing: Theme.spaceS) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(activity.project)
                            .bold()
                        Text("· \(activity.detail)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .help("\(activity.project): \(activity.detail)")
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, Theme.spaceM)
        .padding(.vertical, Theme.spaceS)
        .frame(minHeight: 34)
        .accessibilityElement(children: .combine)
    }

    private var activities: [ProjectActivity] {
        var rows: [ProjectActivity] = []
        if store.isBuilderRendering {
            rows.append(
                ProjectActivity(
                    id: "builder",
                    project: store.builderRenderProjectName ?? "Project",
                    detail: "Rendering timeline"
                ))
        }
        if store.isAnalyzing {
            rows.append(
                ProjectActivity(
                    id: "analysis",
                    project: store.analysisProjectName ?? "Project",
                    detail: store.analysisStage.isEmpty ? "Analyzing" : store.analysisStage
                ))
        }
        if store.isPipelineRunning {
            rows.append(
                ProjectActivity(
                    id: "pipeline",
                    project: store.pipelineProjectName ?? "Project",
                    detail: store.pipelineStage.isEmpty ? "Running pipeline" : store.pipelineStage
                ))
        }
        if store.isWizardRunning, let status = store.wizardStatus {
            rows.append(
                ProjectActivity(
                    id: "wizard",
                    project: store.wizardProjectName ?? "Project",
                    detail: status.stage
                ))
        }
        return rows
    }
}

private struct ProjectActivity: Identifiable {
    let id: String
    let project: String
    let detail: String
}
