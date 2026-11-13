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
    /// The palette slot of a row's clip id: the colour its item has in its
    /// Footage section, drawn as the row's left bar. Nil: no bar.
    var barSlot: ((String) -> Int?)? = nil
    /// What ties a clip to its neighbours as passages of one item (a
    /// transcript pick made of several), by clip id: rows next to each
    /// other with the same key share the item's bar. Unlisted: the clip
    /// stands alone.
    var groupKeys: [String: String] = [:]
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
    /// The drag started on an item's bar: all its passages move as one.
    @State private var draggingItem = false
    @State private var dragTranslation: CGFloat = 0
    @State private var dropSlot: Int?
    @State private var rowFrames: [String: CGRect] = [:]
    @FocusState private var listFocused: Bool
    @State private var confirmRemoveAll = false

    private static let listSpace = "wizardPreview.list"
    private static let collapsedLines = 2
    private static let rowSpacing: CGFloat = 2
    /// The strip over an item's bar that drags the whole item.
    private static let itemHandleWidth: CGFloat = 10

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
        .speakerColors(for: Set(rows.flatMap { $0.segments.compactMap(\.speaker) }))
        .onChange(of: linesVersion) { _, _ in rebuildRows() }
        .onChange(of: rows.map(\.id)) { _, ids in expanded.formIntersection(ids) }
    }

    private var header: some View {
        HStack(spacing: Theme.spaceS) {
            SectionLabel(rows.count == 1 ? "1 clip" : "\(rows.count) clips")
            if !rows.isEmpty {
                // Everything in the reel, end to end.
                durationLabel(rows.reduce(0) { $0 + $1.duration })
                    .help("Total length of the clips in the reel")
                    .accessibilityLabel("Total length \(Self.clock(rows.reduce(0) { $0 + $1.duration }))")
            }
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
                        Text("Each clip is unselected in its Footage section; Fight-metrics stretches are deleted.")
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
            let dragged = draggedIDs
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    let isDragging = dragged.contains(row.id)
                    rowView(row, index: index)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: PreviewRowFramePreference.self,
                                                   value: [row.id: geometry.frame(in: .named(Self.listSpace))])
                        })
                        .offset(y: isDragging ? dragTranslation : 0)
                        .opacity(isDragging ? 0.75 : 1)
                        .zIndex(isDragging ? 1 : 0)
                        .highPriorityGesture(reorderGesture(row), including: canReorder ? .all : .subviews)
                        .help(canReorder ? "Double-click to expand or collapse; drag to reorder" : "Double-click to expand or collapse")
                        .contextMenu {
                            if !row.text.isEmpty {
                                Button(expanded.contains(row.id) ? "Collapse" : "Expand") { toggleExpanded(row) }
                            }
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
            .onChange(of: listFocused, initial: true) { _, focused in store.miniReelListFocused = focused }
            .onDisappear { store.miniReelListFocused = false }
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
        // A row that is one of several passages of the same item: the item's
        // bar runs unbroken down them and each has a thinner bar of its own.
        let key = barGroupKey(row)
        let joinsAbove = index > 0 && barGroupKey(rows[index - 1]) == key
        let joinsBelow = index + 1 < rows.count && barGroupKey(rows[index + 1]) == key
        let grouped = (joinsAbove || joinsBelow) && config.barSlot?(row.id) != nil
        let bridge = Self.rowSpacing / 2
        // No buttons on the card: a click selects, a double-click expands or
        // collapses, and the context menu carries Expand, Select and Delete.
        return VStack(alignment: .leading, spacing: 2) {
            Button { selectedIndex = index; listFocused = true } label: {
                // Only who is talking and what they said; the Video tab's
                // stepper carries the clip number and time.
                Group {
                    if row.text.isEmpty {
                        Text("No words or description for this clip")
                            .font(.body).foregroundStyle(.secondary)
                    } else if !row.segments.isEmpty {
                        speakerTurns(row, expanded: isExpanded)
                    } else {
                        VStack(alignment: .leading, spacing: Theme.spaceXS) {
                            durationLabel(row.duration).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(row.text)
                                .font(.body)
                                .foregroundStyle(row.textKind == .description ? .secondary : .primary)
                                .italic(row.textKind == .description)
                                .lineLimit(isExpanded ? nil : Self.collapsedLines)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { toggleExpanded(row) })
            .accessibilityLabel("Clip \(index + 1), \(row.title)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") { toggleExpanded(row) }
        }
        .padding(Theme.spaceS)
        .padding(.leading, RangeReviewPalette.barWidth + (grouped ? RangeReviewPalette.cutBarInset : 0))
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            // The colour this clip's item has in its Footage section.
            if let slot = config.barSlot?(row.id) {
                ZStack(alignment: .leading) {
                    RangeReviewPalette.bar(slot)
                        .frame(width: RangeReviewPalette.barWidth)
                        .padding(.top, grouped && joinsAbove ? -bridge : Theme.spaceXS)
                        .padding(.bottom, grouped && joinsBelow ? -bridge : Theme.spaceXS)
                    if grouped {
                        RangeReviewPalette.cutBar(slot)
                            .frame(width: RangeReviewPalette.barWidth / 2)
                            .padding(.vertical, Theme.spaceXS)
                            .padding(.leading, RangeReviewPalette.cutBarInset)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                if grouped, canReorder {
                    // The item's bar is the handle for the whole item; the
                    // row's drag reads where it started (`reorderGesture`).
                    Color.clear
                        .frame(width: Self.itemHandleWidth)
                        .contentShape(Rectangle())
                        .pointerStyle(draggingID == nil ? .grabIdle : .grabActive)
                        .help("Drag up or down to move this item with all its passages")
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, Theme.spaceXS)
    }

    /// The item a row is a passage of: the owner's key, else the rows that
    /// move together (one take's cuts).
    private func barGroupKey(_ row: WizardPreviewRow) -> String {
        config.groupKeys[row.id] ?? WizardPreviewRows.blockKey(row.id)
    }

    /// One block per speaker turn, a blank line apart: the speaker's name
    /// as a pill in the transcript's colour for them, the words under it.
    /// Collapsed, only the first turn shows, cut to the collapsed lines.
    private func speakerTurns(_ row: WizardPreviewRow, expanded: Bool) -> some View {
        let turns = expanded ? row.segments : Array(row.segments.prefix(1))
        return VStack(alignment: .leading, spacing: Theme.spaceL) {
            ForEach(turns.indices, id: \.self) { index in
                let turn = turns[index]
                VStack(alignment: .leading, spacing: Theme.spaceXS) {
                    // The clip's length sits on its first speaker's line, at
                    // the row's right edge.
                    if index == 0 {
                        HStack(spacing: Theme.spaceS) {
                            if let speaker = turn.speaker { SpeakerPill(speaker: speaker) }
                            Spacer(minLength: Theme.spaceS)
                            durationLabel(row.duration)
                        }
                    } else if let speaker = turn.speaker {
                        SpeakerPill(speaker: speaker)
                    }
                    // Collapsed with later turns hidden: the shown turn ends
                    // in "…" even when its own words fit.
                    Text(!expanded && row.segments.count > 1 ? turn.text + " …" : turn.text)
                        .font(.body)
                        .lineLimit(expanded ? nil : Self.collapsedLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func durationLabel(_ seconds: Double) -> some View {
        Text(Self.clock(seconds))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
    }

    /// Minutes and seconds to the nearest second ("0:12").
    static func clock(_ seconds: Double) -> String {
        WizardPreviewClips.clock(max(0, seconds).rounded())
    }

    private func toggleExpanded(_ row: WizardPreviewRow) {
        guard !row.text.isEmpty else { return }
        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
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
    /// Dragged by its item's bar, a row moves with every neighbour that is
    /// a passage of the same item.
    private var blocks: [[WizardPreviewRow]] {
        guard draggingItem else { return WizardPreviewRows.blocks(rows) }
        var result: [[WizardPreviewRow]] = []
        for row in rows {
            if let last = result.last?.last, barGroupKey(last) == barGroupKey(row) {
                result[result.count - 1].append(row)
            } else {
                result.append([row])
            }
        }
        return result
    }

    /// Boundaries between blocks, top of the first to bottom of the last.
    private var dropBoundaries: [CGFloat] {
        let frames = blocks.map { block in block.compactMap { rowFrames[$0.id] } }
        guard frames.allSatisfy({ !$0.isEmpty }), let last = frames.last else { return [] }
        return frames.map { $0.map(\.minY).min() ?? 0 } + [last.map(\.maxY).max() ?? 0]
    }

    /// The dragged row and the rest of its block.
    private var draggedIDs: Set<String> {
        guard let draggingID else { return [] }
        return Set(blocks.first { $0.contains { $0.id == draggingID } }?.map(\.id) ?? [])
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
                if draggingID == nil {
                    // Rows sit `spaceXS` in from the list's edge; the bar starts there.
                    draggingItem = value.startLocation.x < Theme.spaceXS + Self.itemHandleWidth
                }
                draggingID = row.id
                dragTranslation = value.translation.height
                let boundaries = dropBoundaries
                guard !boundaries.isEmpty else { return }
                dropSlot = boundaries.indices.min { abs(boundaries[$0] - value.location.y) < abs(boundaries[$1] - value.location.y) }
            }
            .onEnded { _ in
                defer { draggingID = nil; draggingItem = false; dragTranslation = 0; dropSlot = nil }
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
