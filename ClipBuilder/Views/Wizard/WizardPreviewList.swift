import SwiftUI

/// What the preview column's List tab needs from its owner.
struct WizardPreviewListConfig {
    /// The kept clips' ids in their new order after a drop.
    var onReorder: ([String]) -> Void
    var canReorder = true
    /// Delete on a row (context menu or the Delete key on the selected row):
    /// the clip id to take out of the reel.
    var onDelete: ((String) -> Void)? = nil
    /// Remove All in the header, after a confirmation.
    var onDeleteAll: (() -> Void)? = nil
    /// Select on a row: open the clip's Footage section with the item selected.
    var onSelect: ((String) -> Void)? = nil
    /// A third tab, Summary: what Generate will make. The column's footer is
    /// then only the action buttons, pinned without a split.
    var summary: AnyView? = nil
}

/// The Express preview's List tab: every kept clip in output order, with its
/// title and time and its transcript (speaker names start each speaker's
/// stretch) or scene description, two lines until expanded. Rows drag to
/// reorder, a click makes the row the Video tab's current clip, and Delete
/// (context menu or key) takes the clip out of the reel.
struct WizardPreviewList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.isEnabled) private var isEnabled
    let clips: [WizardPreviewClip]
    @Binding var selectedIndex: Int
    let config: WizardPreviewListConfig
    var emptyMessage = "No kept footage yet"

    @State private var lines: [Int64: [WizardPreviewRows.Line]] = [:]
    /// Bumped when `lines` loads; the rebuild then reads the current clips
    /// rather than the ones the loading task started with.
    @State private var linesVersion = 0
    @State private var expanded: Set<String> = []
    @State private var draggingID: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var dropSlot: Int?
    @State private var rowFrames: [String: CGRect] = [:]
    @FocusState private var listFocused: Bool
    @State private var confirmRemoveAll = false

    private static let listSpace = "wizardPreview.list"
    private static let collapsedLines = 2

    /// Built once per change of the clips or the words: the rows are read
    /// from the header, the list and every row's closures, and building them
    /// filters each recording's words per clip.
    @State private var rows: [WizardPreviewRow] = []
    private var videoIDs: [Int64] { Array(Set(clips.map(\.scene.videoID))).sorted() }
    private var canReorder: Bool { config.canReorder && isEnabled && rows.count > 1 }
    private var canDelete: Bool { config.onDelete != nil && isEnabled }
    private var canDeleteAll: Bool { config.onDeleteAll != nil && isEnabled && !rows.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            header
            if rows.isEmpty {
                Text(emptyMessage).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                list
            }
        }
        // Transcript edits and re-transcriptions bump the counts version.
        .task(id: "\(videoIDs) \(store.transcriptCountsVersion)") { await loadLines() }
        .onChange(of: clips, initial: true) { _, _ in rebuildRows() }
        .onChange(of: linesVersion) { _, _ in rebuildRows() }
        .onChange(of: rows.map(\.id)) { _, ids in expanded.formIntersection(ids) }
    }

    private var header: some View {
        HStack(spacing: Theme.spaceS) {
            SectionLabel(rows.count == 1 ? "1 clip" : "\(rows.count) clips")
            Spacer(minLength: 0)
            // One toggle: expands while any clip is collapsed, else collapses.
            let expandable = Set(rows.filter { !$0.text.isEmpty }.map(\.id))
            let allExpanded = !expandable.isEmpty && expandable.isSubset(of: expanded)
            Button(allExpanded ? "Collapse All" : "Expand All") {
                expanded = allExpanded ? [] : expandable
            }
            .disabled(expandable.isEmpty)
            .help(allExpanded ? "Show two lines of text per clip" : "Show every clip's full text")
            if canDeleteAll {
                Button("Remove All", systemImage: "trash") { confirmRemoveAll = true }
                    .labelStyle(.iconOnly)
                    .help("Remove every clip from the reel")
                    .confirmationDialog("Remove all \(rows.count) clips from the reel?", isPresented: $confirmRemoveAll,
                                        titleVisibility: .visible) {
                        Button("Remove All", role: .destructive) { config.onDeleteAll?() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Each clip is unselected in its Footage section.")
                    }
            }
        }
        .controlSize(.small)
        .lineLimit(1).fixedSize(horizontal: false, vertical: true)
    }

    private var list: some View {
        ScrollView {
            // Plain VStack: every row needs a frame for the drop maths, and
            // the kept list is short.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row, index: index)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: PreviewRowFramePreference.self,
                                                   value: [row.id: geometry.frame(in: .named(Self.listSpace))])
                        })
                        .offset(y: isDragging(row) ? dragTranslation : 0)
                        .opacity(isDragging(row) ? 0.75 : 1)
                        .zIndex(isDragging(row) ? 1 : 0)
                        .highPriorityGesture(reorderGesture(row), including: canReorder ? .all : .subviews)
                        .help(canReorder ? "Drag up or down to reorder" : "")
                        .contextMenu {
                            if let onSelect = config.onSelect {
                                Button("Select") { selectedIndex = index; onSelect(row.id) }
                            }
                            if canDelete {
                                Button("Delete", role: .destructive) { config.onDelete?(row.id) }
                            }
                        }
                }
            }
            .padding(.vertical, Theme.spaceXS)
            .coordinateSpace(name: Self.listSpace)
            // The Delete key removes the selected row once the list has focus
            // (a row click gives it focus).
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onDeleteCommand { deleteSelected() }
            .onPreferenceChange(PreviewRowFramePreference.self) { rowFrames = $0 }
            .overlay(alignment: .topLeading) {
                if draggingID != nil, let y = dropMarkerY {
                    Capsule().fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, Theme.spaceS)
                        .offset(y: y - 1.5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func rowView(_ row: WizardPreviewRow, index: Int) -> some View {
        let selected = index == selectedIndex
        let isExpanded = expanded.contains(row.id)
        return HStack(alignment: .top, spacing: Theme.spaceS) {
            Button { selectedIndex = index; listFocused = true } label: {
                // Only who is talking and what they said; the Video tab's
                // stepper carries the clip number and time.
                Group {
                    if row.text.isEmpty {
                        Text("No words or description for this clip")
                            .font(.body).foregroundStyle(.secondary)
                    } else {
                        rowText(row)
                            .font(.body)
                            .foregroundStyle(row.textKind == .description ? .secondary : .primary)
                            .italic(row.textKind == .description)
                            .lineLimit(isExpanded ? nil : Self.collapsedLines)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clip \(index + 1), \(row.title)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            if !row.text.isEmpty {
                Button(isExpanded ? "Collapse" : "Expand",
                       systemImage: isExpanded ? "chevron.up" : "chevron.down") {
                    if isExpanded { expanded.remove(row.id) } else { expanded.insert(row.id) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(isExpanded ? "Show two lines" : "Show the whole text")
            }
        }
        .padding(Theme.spaceS)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, Theme.spaceXS)
    }

    /// Speaker names, in the transcript's colour for that speaker, at the
    /// start of each stretch they speak; the words in regular body text.
    private func rowText(_ row: WizardPreviewRow) -> Text {
        guard !row.segments.isEmpty else { return Text(row.text) }
        return row.segments.enumerated().reduce(Text("")) { text, item in
            let (index, segment) = item
            let name = segment.speaker.map {
                Text("\($0): ").fontWeight(.semibold).foregroundColor(SpeakerColors.color(for: $0))
            } ?? Text("")
            return text + Text(index == 0 ? "" : " ") + name + Text(segment.text)
        }
    }

    /// The selected row leaves the reel; the next row (or the last) is selected.
    private func deleteSelected() {
        guard canDelete, rows.indices.contains(selectedIndex) else { return }
        let id = rows[selectedIndex].id
        config.onDelete?(id)
        selectedIndex = max(0, min(selectedIndex, rows.count - 2))
    }

    // MARK: - Reorder

    /// Rows sharing an owner (one take's cuts) move as one block.
    private var blocks: [[WizardPreviewRow]] { WizardPreviewRows.blocks(rows) }

    /// Boundaries between blocks, top of the first to bottom of the last.
    private var dropBoundaries: [CGFloat] {
        let frames = blocks.map { block in block.compactMap { rowFrames[$0.id] } }
        guard frames.allSatisfy({ !$0.isEmpty }), let last = frames.last else { return [] }
        return frames.map { $0.map(\.minY).min() ?? 0 } + [last.map(\.maxY).max() ?? 0]
    }

    /// The dragged row and the rest of its block.
    private func isDragging(_ row: WizardPreviewRow) -> Bool {
        guard let draggingID else { return false }
        return row.id == draggingID || WizardPreviewRows.blockKey(row.id) == WizardPreviewRows.blockKey(draggingID)
    }

    private var dropMarkerY: CGFloat? {
        guard let dropSlot else { return nil }
        let boundaries = dropBoundaries
        return boundaries.indices.contains(dropSlot) ? boundaries[dropSlot] : nil
    }

    private func reorderGesture(_ row: WizardPreviewRow) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                guard canReorder else { return }
                draggingID = row.id
                dragTranslation = value.translation.height
                let boundaries = dropBoundaries
                guard !boundaries.isEmpty else { return }
                dropSlot = boundaries.indices.min { abs(boundaries[$0] - value.location.y) < abs(boundaries[$1] - value.location.y) }
            }
            .onEnded { _ in
                defer { draggingID = nil; dragTranslation = 0; dropSlot = nil }
                guard canReorder, let slot = dropSlot else { return }
                let ids = rows.map(\.id)
                let reordered = WizardPreviewRows.reorderedIDs(blocks: blocks.map { $0.map(\.id) },
                                                              moving: row.id, toSlot: slot)
                guard reordered != ids else { return }
                // The dragged clip stays current after the drop.
                let currentID = rows.indices.contains(selectedIndex) ? rows[selectedIndex].id : nil
                config.onReorder(reordered)
                if let currentID, let at = reordered.firstIndex(of: currentID) { selectedIndex = at }
            }
    }

    // MARK: - Transcript lines

    private func rebuildRows() {
        let built = WizardPreviewRows.rows(clips: clips, lines: lines)
        if built != rows { rows = built }
    }

    /// Each recording's rows with their speaker labels, decoded off the main actor.
    private func loadLines() async {
        guard let database = store.database else { return }
        let people = store.people
        var result: [Int64: [WizardPreviewRows.Line]] = [:]
        for videoID in videoIDs {
            guard let rows = try? await database.fetchTranscripts(videoID: videoID) else { continue }
            let speakers = await store.speakerTurns(videoID: videoID)
            if Task.isCancelled { return }
            result[videoID] = await Task.detached(priority: .userInitiated) {
                let named = TranscriptSpeakers.named(speakers.turns, roster: speakers.roster)
                return WizardPreviewRows.lines(rows: rows) {
                    TranscriptSpeakers.label(for: $0, turns: named, roster: speakers.roster, people: people)
                }
            }.value
        }
        if !Task.isCancelled { lines = result; linesVersion += 1 }
    }
}

private struct PreviewRowFramePreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
