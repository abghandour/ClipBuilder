import SwiftUI

/// Express Fight metrics: the picks on the left, the player with its trimmer
/// in the middle, the scored actions on the right. Select actions in the grid;
/// Add turns each unbroken run of them into one pick.
struct MiniFightPickView: View {
    @Environment(AppStore.self) private var store
    let run: MiniWizardRun
    /// Scored event ids chosen in the grid; the draft previews them.
    @State private var chosen: Set<Int64> = []
    /// A hand trim of the draft; nil = the chosen actions' own span.
    @State private var draftRange: ClosedRange<Double>?
    @State private var selectedOwner: Int64?

    /// The draft's owner ID can never collide with a stored pick.
    private static let draftOwnerID: Int64 = -1

    private var fight: MiniWizardFight? {
        store.miniRun?.batchID == run.batchID ? store.miniRun?.fight : run.fight
    }
    private var actions: [MiniWizardFightRules.Action] { fight?.actions ?? [] }
    private var picks: [FightPick] { fight?.picks ?? [] }
    private var names: [String: String] { fight?.names ?? [:] }
    private var limits: ClosedRange<Double> { 0...max(run.video.duration, ProposedCutTrim.minimumSpan) }

    /// The chosen actions in time order.
    private var chosenActions: [MiniWizardFightRules.Action] {
        actions.filter { chosen.contains($0.id) }
    }

    /// What the draft previews and "as one" adds: the stretch from the
    /// earliest chosen action to the latest, or the hand trim of it.
    private var draft: ClosedRange<Double> {
        if let draftRange { return draftRange }
        if let span = MiniWizardFightRules.span(of: chosenActions) { return span }
        let at = min(limits.upperBound, max(0, picks.last?.end ?? 0))
        return at...at
    }

    private var items: [RangeReviewItem] {
        let empty = draft.upperBound <= draft.lowerBound
        let draftCaption = empty ? "Select actions in the grid"
            : chosen.count > 1 ? "\(chosen.count) actions · \(RangeReviewItem.rangeCaption(draft))"
            : RangeReviewItem.rangeCaption(draft)
        let draftItem = RangeReviewItem(id: .init(ownerID: Self.draftOwnerID), title: "New pick",
            titleHelp: "Select one or more actions in the grid, adjust the stretch, then press Add.",
            keepLabel: "New pick",
            captions: [.init(text: draftCaption, monospaced: !empty)],
            video: run.video, range: draft, originalRange: draft, limits: limits, trimPolicy: .pick,
            isAvailable: run.video.isPresent, isDraft: true)
        let pickItems = picks.enumerated().map { index, pick in
            RangeReviewItem(id: .init(ownerID: pick.id),
                title: "\(index + 1). " + MiniWizardFightRules.title(for: pick, actions: actions, names: names, number: index + 1),
                titleHelp: MiniWizardFightRules.title(for: pick, actions: actions, names: names, number: index + 1, limit: 200),
                keepLabel: "Pick \(index + 1)",
                captions: [.init(text: RangeReviewItem.rangeCaption(pick.range), monospaced: true)],
                video: run.video, range: pick.range, originalRange: pick.originalRange, limits: limits,
                trimPolicy: .wizard, isAvailable: run.video.isPresent, titleLines: 2)
        }
        return [draftItem] + pickItems
    }

    var body: some View {
        if actions.isEmpty {
            noActions
        } else {
            RangeReviewView(items: items, rows: [], labels: [:],
                            selection: $selectedOwner,
                            emptyTitle: "Pick an action",
                            emptyMessage: "Select actions in the grid, adjust the stretch, then press Add.",
                            resetTitle: "Reset to Added", autoplay: false, transcriptLeading: true,
                            listTitle: picks.isEmpty ? "Picks" : (picks.count == 1 ? "1 pick" : "\(picks.count) picks"),
                            onMove: { store.reorderMiniFightPicks($0) },
                            onDelete: { item in store.deleteMiniFightPick(item.id.ownerID) },
                            onDeleteAll: { store.deleteAllMiniFightPicks() },
                            playAll: true,
                            leadingPanel: AnyView(grid),
                            emptyDraftHint: "Select one or more actions in the grid to preview them here.",
                            trimHint: "Drag the handles to adjust · I / O set the start / end at the playhead",
                            onSave: save) { item in
                if item.isDraft {
                    draftFooter(item)
                } else if let pick = picks.first(where: { $0.id == item.id.ownerID }) {
                    pickFooter(pick)
                }
            }
            .onChange(of: run.batchID) { _, _ in chosen = []; draftRange = nil }
            .onChange(of: chosen) { _, _ in
                draftRange = nil
                if !chosen.isEmpty { selectedOwner = Self.draftOwnerID }
            }
        }
    }

    private var noActions: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            FormCaption("No fight actions were scored for this video. Run the fight scoring pass on the Analyze page, then come back.")
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Button { store.requestedSection = .analyze } label: {
                Text("Open Analyze").lineLimit(1).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The chronological action grid: time, fighter, action. Plain rows in a
    /// scroll view with click, ⇧ and ⌘ selection; a SwiftUI Table here
    /// crashed in AppKit's coordinator when the card collapsed under it.
    private var grid: some View {
        let pickedIDs = Set(picks.flatMap(\.eventIDs))
        return VStack(alignment: .leading, spacing: 0) {
            gridRow(time: "Time", fighter: "Fighter", action: "Action", header: true)
                .padding(.horizontal, Theme.spaceS)
                .padding(.vertical, Theme.spaceXS)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(actions) { action in
                            let selected = chosen.contains(action.id)
                            let picked = pickedIDs.contains(action.id)
                            HStack(spacing: Theme.spaceXS) {
                                gridRow(time: action.time.timecode,
                                        fighter: names[action.fighterKey] ?? (action.fighterKey.isEmpty ? "—" : action.fighterKey),
                                        action: action.label, header: false)
                                if picked {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(selected ? .white : .secondary)
                                        .help("Already in a pick")
                                }
                            }
                            .foregroundStyle(selected ? Color.white : picked ? Color.secondary : Color.primary)
                            .padding(.horizontal, Theme.spaceS)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected ? Color.accentColor : Color.clear)
                            .contentShape(Rectangle())
                            .id(action.id)
                            .onTapGesture { click(action.id) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
                .onChange(of: chosenScrollTarget) { _, target in
                    if let target { proxy.scrollTo(target) }
                }
            }
            Divider()
            FormCaption(chosen.isEmpty
                ? "\(actions.count) scored actions. Click to select; ⇧ and ⌘ extend the selection."
                : "\(chosen.count) selected")
                .lineLimit(1).truncationMode(.tail)
                .padding(Theme.spaceS)
        }
    }

    /// Three aligned columns: a fixed time, a fighter column, the action taking the rest.
    private func gridRow(time: String, fighter: String, action: String, header: Bool) -> some View {
        HStack(spacing: Theme.spaceS) {
            Text(time).monospacedDigit().frame(width: 44, alignment: .leading)
            Text(fighter).lineLimit(1).truncationMode(.tail).frame(width: 96, alignment: .leading)
            Text(action).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(header ? .caption.weight(.semibold) : .body)
        .foregroundStyle(header ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }

    /// The last clicked row, for ⇧ ranges and keeping the row in view.
    @State private var anchor: Int64?
    private var chosenScrollTarget: Int64? { anchor.flatMap { chosen.contains($0) ? $0 : nil } }

    private func click(_ id: Int64) {
        let modifiers = NSEvent.modifierFlags
        let result = MiniWizardFightRules.select(id, in: actions.map(\.id), current: chosen, anchor: anchor,
                                                 command: modifiers.contains(.command), shift: modifiers.contains(.shift))
        chosen = result.selected
        anchor = result.anchor
    }

    private func save(_ item: RangeReviewItem, start: Double, end: Double) {
        if item.isDraft {
            draftRange = end > start ? start...end : nil
        } else {
            store.setMiniFightPickRange(item.id.ownerID, start: start, end: end)
        }
    }

    /// One action: Add Pick. Several: each as its own pick, or all as one
    /// stretch from the earliest to the latest (the trimmed draft).
    private func draftFooter(_ item: RangeReviewItem) -> some View {
        let selected = chosenActions
        let count = selected.count
        let blocked = count == 0 || store.isWizardRunning || !item.isAvailable
        return VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(spacing: Theme.spaceS) {
                Button {
                    if count == 1 {
                        add([(range: draftRange ?? selected[0].range, eventIDs: [selected[0].id])])
                    } else {
                        add(selected.map { (range: $0.range, eventIDs: [$0.id]) })
                    }
                } label: {
                    Text(count > 1 ? "Add \(count) Separate Picks" : "Add Pick").lineLimit(1).fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .disabled(blocked)
                .help(count > 1 ? "One pick per selected action, each with its own half-second run-up and follow-through"
                      : "Add the previewed stretch as a pick")
                if count > 1 {
                    Button {
                        add([(range: draft, eventIDs: selected.map(\.id))])
                    } label: {
                        Text("Add as One Pick").lineLimit(1).fixedSize()
                    }
                    .disabled(blocked)
                    .help("One pick from the earliest selected action to the latest, as previewed and trimmed")
                }
            }
            FormCaption(count == 0 ? "Select actions first."
                        : count == 1 ? "Adds the previewed stretch and clears the selection."
                        : "Separate picks can take a transition between them; one pick plays the whole stretch uncut.")
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add(_ picks: [(range: ClosedRange<Double>, eventIDs: [Int64])]) {
        store.addMiniFightPicks(picks)
        chosen = []
        draftRange = nil
    }

    private func pickFooter(_ pick: FightPick) -> some View {
        Button(role: .destructive) {
            store.deleteMiniFightPick(pick.id)
        } label: {
            Text("Delete").lineLimit(1).fixedSize()
        }
        .disabled(store.isWizardRunning)
        .help("Remove this pick")
    }
}
