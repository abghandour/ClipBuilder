import SwiftUI

struct TimelinesView: View {
    @Environment(AppStore.self) private var store
    @State private var renameTarget: TimelineRecord?
    @State private var renameText = ""
    @State private var deleteTarget: TimelineRecord?

    var body: some View {
        Group {
            if store.timelines.isEmpty {
                ContentUnavailableView {
                    Label("No Timelines", systemImage: "timeline.selection")
                } description: {
                    Text(
                        "Create a timeline from scratch or ask the Wizard to build a first cut from this project’s scenes."
                    )
                } actions: {
                    Button("New Timeline", systemImage: "plus", action: newTimeline)
                    Button("New from Wizard…", systemImage: "wand.and.stars", action: openWizard)
                }
            } else {
                List(store.timelines) { timeline in
                    TimelineRowView(
                        timeline: timeline,
                        onOpen: { store.openTimelineRecord(timeline) },
                        onRename: { beginRename(timeline) },
                        onDuplicate: { store.duplicateTimeline(timeline) },
                        onDelete: { deleteTarget = timeline }
                    )
                }
            }
        }
        .screenTitle("Timelines", subtitle: subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button("New Timeline", systemImage: "plus", action: newTimeline)
                Button("New from Wizard…", systemImage: "wand.and.stars", action: openWizard)
                    .buttonStyle(.borderedProminent)
            }
        }
        .alert(
            "Rename Timeline",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Timeline name", text: $renameText)
            Button("Rename", action: renameTimeline)
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Delete \(deleteTarget?.name ?? "timeline")?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Delete Timeline", role: .destructive, action: deleteTimeline)
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
    }

    private var subtitle: String {
        let builders = store.timelines.count { !$0.isWizard }
        let wizards = store.timelines.count(where: \.isWizard)
        return "\(store.activeProject?.name ?? "Project") · \(builders) Builder, \(wizards) Wizard"
    }

    private func openWizard() {
        store.selectSection(.wizard)
    }

    private func newTimeline() {
        store.createTimeline()
    }

    private func beginRename(_ timeline: TimelineRecord) {
        renameTarget = timeline
        renameText = timeline.name
    }

    private func renameTimeline() {
        if let renameTarget { store.renameTimeline(renameTarget, to: renameText) }
        renameTarget = nil
    }

    private func deleteTimeline() {
        if let deleteTarget { store.deleteTimeline(deleteTarget) }
        deleteTarget = nil
    }
}
