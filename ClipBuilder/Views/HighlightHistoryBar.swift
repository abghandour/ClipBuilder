import SwiftUI

/// Highlight history selector (docs/Highlight-History-Plan.md, Phase 2):
/// Previous, a menu of every saved highlight (newest first, the current one
/// checked), Next, Open, and the caller's Re-render / Generate again. The
/// entries come from `AppStore.highlightHistories`; the caller performs the
/// actions. Every label is one line; narrower widths drop the long title.
struct HighlightHistoryBar: View {
    let entries: [WizardHighlightRecord]
    let selectedID: Int64?
    /// Entries whose source video this library lacks: listed, not openable.
    let unavailable: Set<Int64>
    /// Extra tooltip for the current entry (the full wizard's plan summary).
    var currentHelp: String?
    var disabled = false
    let reRenderTitle: String
    let reRenderHelp: String
    /// Choose an entry and open it (menu, Previous, Next).
    let onSelect: (Int64) -> Void
    let onOpen: (Int64) -> Void
    let onReRender: (Int64) -> Void

    private var currentIndex: Int? {
        selectedID.flatMap { id in entries.firstIndex { $0.id == id } }
    }

    private var current: WizardHighlightRecord? { currentIndex.map { entries[$0] } }

    private var currentAvailable: Bool {
        guard let current else { return false }
        return !unavailable.contains(current.id)
    }

    private var countTitle: String { "History (\(entries.count))" }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(title: current.map { HighlightHistoryNavigation.shortLabel(for: $0) } ?? countTitle, reRenderLabel: true)
            row(title: countTitle, reRenderLabel: true)
            row(title: countTitle, reRenderLabel: false)
        }
        .controlSize(.small)
        .disabled(disabled)
    }

    private func row(title: String, reRenderLabel: Bool) -> some View {
        HStack(spacing: Theme.spaceS) {
            Button {
                if let index = HighlightHistoryNavigation.previousIndex(current: currentIndex, count: entries.count) {
                    onSelect(entries[index].id)
                }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(HighlightHistoryNavigation.previousIndex(current: currentIndex, count: entries.count) == nil)
            .help("Open the previous (older) highlight")
            .accessibilityLabel("Previous highlight")

            menu(title: title)

            Button {
                if let index = HighlightHistoryNavigation.nextIndex(current: currentIndex, count: entries.count) {
                    onSelect(entries[index].id)
                }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(HighlightHistoryNavigation.nextIndex(current: currentIndex, count: entries.count) == nil)
            .help("Open the next (newer) highlight")
            .accessibilityLabel("Next highlight")

            Button {
                if let current { onOpen(current.id) }
            } label: {
                Text("Open").lineLimit(1).fixedSize()
            }
            .disabled(!currentAvailable)
            .help(currentAvailable ? "Load this highlight's footage and settings"
                  : current == nil ? "Choose a highlight from the history first" : AppStore.highlightNotInLibrary)

            Button {
                if let current { onReRender(current.id) }
            } label: {
                if reRenderLabel {
                    Label(reRenderTitle, systemImage: "arrow.clockwise").lineLimit(1).fixedSize()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(!currentAvailable)
            .help(currentAvailable ? reRenderHelp
                  : current == nil ? "Choose a highlight from the history first" : AppStore.highlightNotInLibrary)
            .accessibilityLabel(reRenderTitle)
        }
        .fixedSize()
    }

    private func menu(title: String) -> some View {
        Menu {
            if entries.isEmpty {
                Text("No highlights saved yet")
            }
            ForEach(entries) { entry in
                let missing = unavailable.contains(entry.id)
                Toggle(isOn: Binding(get: { entry.id == selectedID }, set: { _ in onSelect(entry.id) })) {
                    Text(HighlightHistoryNavigation.label(for: entry)).lineLimit(1)
                }
                .disabled(missing)
                .help(missing ? AppStore.highlightNotInLibrary : HighlightHistoryNavigation.detail(for: entry))
            }
        } label: {
            Label(title, systemImage: "clock.arrow.circlepath").lineLimit(1).fixedSize()
        }
        .fixedSize()
        .help(menuHelp)
        .accessibilityLabel("Highlight history")
    }

    private var menuHelp: String {
        guard let current else {
            return entries.isEmpty ? "Every generated highlight is saved here with its settings and author"
                : "Choose a saved highlight to open"
        }
        return [HighlightHistoryNavigation.label(for: current), HighlightHistoryNavigation.detail(for: current), currentHelp,
                unavailable.contains(current.id) ? AppStore.highlightNotInLibrary : nil]
            .compactMap { $0 }.joined(separator: "\n")
    }
}

/// The selected entry's warning or what Open loaded, under a history bar.
struct HighlightHistoryCaption: View {
    var warning: String?
    var detail: String?

    var body: some View {
        if let warning {
            FormCaption(warning, tone: .warning)
        } else if let detail {
            FormCaption(detail)
        }
    }
}

/// The full wizard's history for the open project: Open makes the entry's
/// options (sources remapped by video hash) the ones Generate Again runs.
struct WizardHighlightHistoryBar: View {
    @Environment(AppStore.self) private var store
    /// Called after "Generate again" started a run (the results sheet closes).
    var onGenerate: () -> Void = {}
    var showsCaption = true
    @State private var showsClips = false

    private var scope: HighlightHistoryScope? {
        store.activeProjectID.map { HighlightHistoryScope.fullWizard(projectID: $0) }
    }

    private struct LoadKey: Equatable {
        var generation: Int
        var scope: HighlightHistoryScope?
    }

    var body: some View {
        if let scope {
            let selected = store.selectedHighlight(scope)
            let summary = selected.flatMap { HighlightHistoryNavigation.planSummary($0.plan) }
            let opened = store.openedWizardHighlight(for: scope)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: Theme.spaceS) {
                HighlightHistoryBar(entries: store.highlightHistory(scope), selectedID: store.selectedHighlightIDs[scope],
                    unavailable: store.unavailableHighlightIDs,
                    currentHelp: summary.map { "Plan: \($0)" },
                    disabled: store.isWizardRunning,
                    reRenderTitle: "Generate again",
                    reRenderHelp: "Generate again with these settings — a new plan, new videos",
                    onSelect: { id in Task { await store.openWizardHighlight(id: id, scope: scope) } },
                    onOpen: { id in Task { await store.openWizardHighlight(id: id, scope: scope) } },
                    onReRender: { id in
                        Task { if await store.generateWizardHighlightAgain(id: id, scope: scope) { onGenerate() } }
                    })
                Button {
                    showsClips = true
                } label: {
                    Label("Show clips", systemImage: "list.bullet.rectangle").lineLimit(1).fixedSize()
                }
                .controlSize(.small)
                .disabled(opened == nil)
                .help(opened == nil ? "Open a highlight to see its clips" : "List the opened highlight's clips")
                .popover(isPresented: $showsClips, arrowEdge: .bottom) {
                    if let opened {
                        HighlightPlanClipsPopover(opened: opened, disabled: store.isWizardRunning) {
                            showsClips = false
                            store.openWizardHighlightInBuilder(opened)
                            onGenerate()
                        }
                    }
                }
                }
                .fixedSize()
                if showsCaption, let selected {
                    HighlightHistoryCaption(warning: store.highlightOpenWarnings[selected.id],
                        detail: "Opened: " + ([summary, "Generate again runs its settings"].compactMap { $0 }
                            .joined(separator: " · ")))
                }
            }
            .task(id: LoadKey(generation: store.profileGeneration, scope: scope)) {
                await store.loadHighlightHistory(scope)
            }
        }
    }
}

/// The opened full-wizard entry's clips: video, source range, reel seconds,
/// text overlay and kind, plus "Open in Builder".
struct HighlightPlanClipsPopover: View {
    let opened: OpenedWizardHighlight
    var disabled = false
    let onOpenInBuilder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(spacing: Theme.spaceS) {
                Text(HighlightHistoryNavigation.planSummary(opened.plan) ?? "No clips")
                    .font(.headline).lineLimit(1).fixedSize()
                Spacer(minLength: Theme.spaceS)
                Button(action: onOpenInBuilder) {
                    Label("Open in Builder", systemImage: "square.and.pencil").lineLimit(1).fixedSize()
                }
                .disabled(disabled || opened.plan.clips.isEmpty)
                .help("Lay these clips out as a new Builder timeline")
            }
            Divider()
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: Theme.spaceS, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["Kind", "Video", "Source", "Duration", "Text"], id: \.self) { title in
                            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .lineLimit(1).fixedSize()
                        }
                    }
                    ForEach(opened.rows) { row in
                        GridRow {
                            Text(row.kind.rawValue).lineLimit(1).fixedSize()
                                .foregroundStyle(row.kind == .main ? .primary : .secondary)
                            Text(row.videoName).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
                            Text("\(HighlightHistoryNavigation.timecode(row.start))–\(HighlightHistoryNavigation.timecode(row.end))")
                                .monospacedDigit().lineLimit(1).fixedSize()
                            Text(String(format: "%.1f s", row.duration)).monospacedDigit().lineLimit(1).fixedSize()
                            Text(row.textOverlay ?? "").lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: 220, alignment: .leading)
                                .help(row.textOverlay ?? "")
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(Theme.spaceM)
        .frame(minWidth: 480)
    }
}
