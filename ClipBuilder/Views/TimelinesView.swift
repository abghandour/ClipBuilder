import SwiftUI

struct TimelinesView: View {
    @Environment(\.workspacePageVisible) private var pageVisible
    /// Shown from the Builder's All Timelines button: a sheet with its own
    /// header and Close button instead of the window toolbar.
    var presentedAsSheet = false

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var renameTarget: TimelineRecord?
    @State private var renameText = ""
    @State private var deleteTarget: TimelineRecord?

    var body: some View {
        if presentedAsSheet {
            VStack(spacing: 0) {
                sheetHeader
                Divider()
                content
            }
            .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
            .modifier(dialogs)
        } else {
            content
                .screenTitle("Timelines", subtitle: subtitle)
                .toolbar {
                    if pageVisible {
                        ToolbarItemGroup {
                            Button(action: newTimeline) {
                                ToolbarBubbleLabel(text: "New Timeline", systemImage: "plus")
                            }
                            .help("Start an empty timeline in the Builder")
                            Button(action: openWizard) {
                                ToolbarBubbleLabel(text: "New from Wizard", systemImage: "wand.and.stars")
                            }
                            .help("Open the AI Wizard to generate a timeline")
                        }
                    }
                }
                .modifier(dialogs)
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: Theme.spaceS) {
            VStack(alignment: .leading, spacing: 2) {
                Text("All Timelines").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: Theme.spaceM)
            Button("New Timeline", systemImage: "plus", action: newTimeline)
                .fixedSize()
            Button("New from Wizard…", systemImage: "wand.and.stars", action: openWizard)
                .fixedSize()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
                .fixedSize()
        }
        .padding(Theme.spaceM)
    }

    private var dialogs: TimelineDialogs {
        TimelineDialogs(
            renameTarget: $renameTarget,
            renameText: $renameText,
            deleteTarget: $deleteTarget,
            onRename: renameTimeline,
            onDelete: deleteTimeline
        )
    }

    private var content: some View {
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
                let spans = Dictionary(store.historyScenes.map { ($0.id, $0.endTime - $0.startTime) },
                                       uniquingKeysWith: { first, _ in first })
                List(store.timelines) { timeline in
                    TimelineRowView(
                        timeline: timeline,
                        sceneSpans: spans,
                        onOpen: { open(timeline) },
                        onRename: { beginRename(timeline) },
                        onDuplicate: { store.duplicateTimeline(timeline) },
                        onDelete: { deleteTarget = timeline }
                    )
                }
            }
        }
    }

    private var subtitle: String {
        let builders = store.timelines.count { !$0.isWizard }
        let wizards = store.timelines.count(where: \.isWizard)
        return "\(store.activeProject?.name ?? "Project") · \(builders) Builder, \(wizards) Wizard"
    }

    private func open(_ timeline: TimelineRecord) {
        store.openTimelineRecord(timeline)
        if presentedAsSheet { dismiss() }
    }

    private func openWizard() {
        store.selectSection(.wizard)
        if presentedAsSheet { dismiss() }
    }

    private func newTimeline() {
        store.createTimeline()
        if presentedAsSheet { dismiss() }
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

/// Rename alert and delete confirmation shared by the page and the sheet.
private struct TimelineDialogs: ViewModifier {
    @Binding var renameTarget: TimelineRecord?
    @Binding var renameText: String
    @Binding var deleteTarget: TimelineRecord?
    let onRename: () -> Void
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "Rename Timeline",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                )
            ) {
                TextField("Timeline name", text: $renameText)
                Button("Rename", action: onRename)
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .confirmationDialog(
                "Delete \(deleteTarget?.name ?? "timeline")?",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                )
            ) {
                Button("Delete Timeline", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            }
    }
}
