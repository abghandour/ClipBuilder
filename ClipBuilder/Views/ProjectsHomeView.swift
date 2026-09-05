import SwiftUI

struct ProjectsHomeView: View {
    @Environment(AppStore.self) private var store
    @State private var searchText = ""
    @State private var showingNewProject = false
    @State private var newProjectName = ""
    @State private var renameTarget: ProjectRecord?
    @State private var renameText = ""
    @State private var deleteTarget: ProjectRecord?
    @State private var archivedExpanded = false

    private var activeProjects: [ProjectRecord] {
        store.projects.filter { project in
            !project.archived
                && (searchText.isEmpty || project.name.localizedStandardContains(searchText))
        }
    }

    private var archivedProjects: [ProjectRecord] {
        store.projects.filter { project in
            project.archived
                && (searchText.isEmpty || project.name.localizedStandardContains(searchText))
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.spaceXL) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250, maximum: 320), spacing: Theme.spaceL)],
                    alignment: .leading,
                    spacing: Theme.spaceL
                ) {
                    ForEach(activeProjects) { project in
                        ProjectCardView(
                            project: project,
                            onOpen: { store.selectProject(project.id) },
                            onRename: { beginRename(project) },
                            onDuplicate: { store.duplicateProject(project) },
                            onArchive: { store.setProjectArchived(project, archived: true) },
                            onDelete: { deleteTarget = project },
                            onDrop: { store.importVideos($0, toProjectID: project.id) }
                        )
                    }
                }

                if !archivedProjects.isEmpty {
                    DisclosureGroup("Archived (\(archivedProjects.count))", isExpanded: $archivedExpanded) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 250, maximum: 320), spacing: Theme.spaceL)],
                            spacing: Theme.spaceL
                        ) {
                            ForEach(archivedProjects) { project in
                                ProjectCardView(
                                    project: project,
                                    onOpen: {
                                        store.setProjectArchived(project, archived: false)
                                        store.selectProject(project.id)
                                    },
                                    onRename: { beginRename(project) },
                                    onDuplicate: { store.duplicateProject(project) },
                                    onArchive: { store.setProjectArchived(project, archived: false) },
                                    onDelete: { deleteTarget = project },
                                    onDrop: { store.importVideos($0, toProjectID: project.id) }
                                )
                            }
                        }
                        .padding(.top, Theme.spaceM)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.spaceXL)
        }
        .screenTitle("Projects", subtitle: "\(store.projects.count(where: { !$0.archived })) active, \(store.projects.count(where: \.archived)) archived")
        .searchable(text: $searchText, prompt: "Search projects")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Project", systemImage: "plus", action: beginNewProject)
            }
        }
        .alert("New Project", isPresented: $showingNewProject) {
            TextField("Project name", text: $newProjectName)
            Button("Create", action: createProject)
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Rename Project",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Project name", text: $renameText)
            Button("Rename", action: renameProject)
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Delete \(deleteTarget?.name ?? "project")?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Delete Project", role: .destructive) {
                performDelete(moveTimelinesToHome: false)
            }
            if (deleteTarget?.timelineCount ?? 0) > 0 {
                Button("Move Timelines to Home") {
                    performDelete(moveTimelinesToHome: true)
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    private func beginNewProject() {
        newProjectName = ""
        showingNewProject = true
    }

    private func createProject() {
        store.createProject(named: newProjectName)
    }

    private func beginRename(_ project: ProjectRecord) {
        renameTarget = project
        renameText = project.name
    }

    private func renameProject() {
        if let renameTarget { store.renameProject(renameTarget, to: renameText) }
        renameTarget = nil
    }

    private var deleteMessage: String {
        let count = deleteTarget?.timelineCount ?? 0
        if count == 0 {
            return "Source files, scenes, analysis, and outputs stay in Home."
        }
        let timelineLabel = count == 1 ? "timeline" : "timelines"
        return "Deleting this project deletes \(count) \(timelineLabel). "
            + "Source files, scenes, analysis, and outputs stay in Home."
    }

    private func performDelete(moveTimelinesToHome: Bool) {
        if let deleteTarget { store.deleteProject(deleteTarget, moveTimelinesToHome: moveTimelinesToHome) }
        deleteTarget = nil
    }
}
