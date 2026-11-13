import SwiftUI

/// Review of the cleanup cuts the transcript analysis proposes: pauses,
/// filler, repeated words, false starts and retakes. One compact row per
/// cut with the words it removes; the selected row opens for fine-tuning.
/// Cut ones are skipped when a reel is built from the video and by Apply
/// Cleanup Cuts in the Builder. The rules live in `CleanupCutReview`.
struct CleanupCutsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let video: VideoRecord

    @State private var cuts: [EditProposal] = []
    @State private var rows: [TranscriptRow] = []
    @State private var contexts: [Int64: CleanupCutReview.Context] = [:]
    /// False until the transcript has been analyzed at least once.
    @State private var analyzed = false
    @State private var isLoading = true
    @State private var stateFilter = CleanupCutReview.StateFilter.pending
    @State private var kindFilter: EditProposal.Kind?
    /// Cuts decided under the current filter: they stay listed, dimmed,
    /// until the filter changes.
    @State private var sticky: Set<Int64> = []
    @State private var selection: Set<Int64> = []
    /// The row the keys act on and the detail opens under.
    @State private var focusedID: Int64?
    /// Where a Shift-click or Shift-arrow selection starts.
    @State private var anchorID: Int64?
    /// One player for every cut's audition.
    @State private var audition = CutAuditionPlayback()
    @FocusState private var listFocused: Bool

    private var analysisJob: AppJob? { store.jobs.latest(.transcriptAnalysis, subjectID: String(video.id)) }
    private var isAnalyzing: Bool { analysisJob?.status == .running }
    private var summary: CleanupCutReview.Summary { CleanupCutReview.summary(cuts) }
    private var shown: [EditProposal] {
        CleanupCutReview.shown(cuts, state: stateFilter, kind: kindFilter, sticky: sticky)
    }
    /// What the footer's buttons decide: the hand-picked rows, else every row on show.
    private var batchIDs: Set<Int64> {
        let listed = Set(shown.map(\.id))
        let picked = selection.intersection(listed)
        return picked.count > 1 ? picked : listed
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
                .padding(.horizontal).padding(.top, 14).padding(.bottom, 10)
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isAnalyzing {
                working
            } else if cuts.isEmpty {
                empty
            } else {
                summaryBar
                    .padding(.horizontal).padding(.vertical, 10)
                Divider()
                filterBar
                    .padding(.horizontal).padding(.vertical, 8)
                Divider()
                list
                Divider()
                footer
                    .padding(.horizontal).padding(.vertical, 10)
            }
        }
        .frame(minWidth: 900, idealWidth: 900, maxWidth: .infinity,
               minHeight: 440, idealHeight: 640, maxHeight: .infinity)
        .presentationSizing(.fitted)
        .modalCloseButton { dismiss() }
        .task { await load() }
        .onDisappear { audition.tearDown() }
        .appJobSetupPresentation()
        .onChange(of: analysisJob?.status) { _, status in
            guard status != .running else { return }
            // A fresh analysis replaces every cut, and SQLite may hand an
            // old id to a different one: nothing is carried over, and the
            // old rows are not actionable while the new ones load.
            audition.stop()
            isLoading = true
            selection = []
            sticky = []
            focusedID = nil
            anchorID = nil
            Task { await load() }
        }
        .onChange(of: stateFilter) { _, _ in filterChanged() }
        .onChange(of: kindFilter) { _, _ in filterChanged() }
    }

    // MARK: - Bars

    private var titleBar: some View {
        HStack(spacing: 10) {
            SectionLabel("Cleanup Cuts")
            Text(video.filename)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if !cuts.isEmpty, !isAnalyzing {
                Text(thresholds)
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).fixedSize()
                Button("Find Again") { store.startTranscriptAnalysis(video: video) }
                    .controlSize(.small).lineLimit(1).fixedSize()
                    .disabled(rows.isEmpty)
                    .help("Look for pauses, filler, repeats and false starts again with the current thresholds. Cuts you already decided keep their decision; edges you moved by hand go back to where the analysis puts them.")
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .lineLimit(1).fixedSize()
        }
    }

    private var thresholds: String {
        let seconds = store.podcastEditingSettings.deadAirSeconds
        return "Silence over \(seconds.formatted(.number.precision(.fractionLength(0...1)))) s · filler, repeats, false starts"
    }

    private var summaryBar: some View {
        let summary = summary
        return HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(summary.pending.formatted()).font(.title2.weight(.bold)).monospacedDigit()
                    Text("to review").foregroundStyle(.secondary)
                }
                Text("\(summary.total) found · \(summary.cut) cut · \(summary.kept) kept")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .lineLimit(1).fixedSize()
            VStack(alignment: .leading, spacing: 4) {
                Text("−" + CleanupCutReview.length(summary.removedSeconds))
                    .font(.title3.weight(.semibold)).monospacedDigit()
                Text(summary.pending == 0 ? "removed" : "removed so far · up to −\(CleanupCutReview.length(summary.possibleSeconds)) if you cut all")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            Text("Cuts are skipped when a reel is built from this video, and by Apply Cleanup Cuts in the Builder.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .frame(maxWidth: 280, alignment: .trailing)
        }
    }

    private var filterBar: some View {
        let summary = summary
        return HStack(spacing: 8) {
            Picker("Show", selection: $stateFilter) {
                ForEach(CleanupCutReview.StateFilter.allCases) { filter in
                    Text(filter == .all ? filter.label : "\(filter.label) \(summary.count(filter))").tag(filter)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    kindChip(nil, title: "All kinds")
                    ForEach(CleanupCutReview.kinds(cuts, state: stateFilter, sticky: sticky), id: \.kind) { entry in
                        kindChip(entry.kind, title: "\(entry.kind.label) \(entry.count)")
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func kindChip(_ kind: EditProposal.Kind?, title: String) -> some View {
        let on = kindFilter == kind
        return Button {
            kindFilter = kind
        } label: {
            HStack(spacing: 5) {
                if let kind { Circle().fill(Self.color(kind)).frame(width: 7, height: 7) }
                Text(title).font(.callout).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 9).padding(.vertical, 3)
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .background(on ? Color.accentColor.opacity(0.22) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.4)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(kind == nil ? "Show every kind of cut" : "Show only \(kind?.label.lowercased() ?? "") cuts")
    }

    private var footer: some View {
        let ids = batchIDs
        let picked = selection.intersection(Set(shown.map(\.id))).count > 1
        let noun = picked ? "\(ids.count) Selected" : "All \(ids.count) Shown"
        return HStack(spacing: 10) {
            Text("↑ ↓ move · Space hear it · C cut · K keep · Shift-↑↓ or Shift-click selects several")
                .font(.caption).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Keep \(noun)") { decide(.rejected, ids: ids) }
                .lineLimit(1).fixedSize()
                .disabled(ids.isEmpty)
                .help("Leave these in the footage")
            Button("Cut \(noun)") { decide(.accepted, ids: ids) }
                .lineLimit(1).fixedSize()
                .disabled(ids.isEmpty)
                .help("Remove these when a reel is built from this video")
        }
    }

    // MARK: - States

    private var empty: some View {
        VStack(spacing: 12) {
            if analyzed {
                Text("No pauses or filler found").font(.headline)
                Text("Nothing in this transcript passes the thresholds in Settings.")
                    .foregroundStyle(.secondary)
                Button("Find Again") { store.startTranscriptAnalysis(video: video) }
                    .disabled(rows.isEmpty)
            } else {
                Text(rows.isEmpty ? "This video has no transcript yet." : "Nothing has been looked for in this transcript yet.")
                    .foregroundStyle(.secondary)
                Button("Find Pauses & Filler") { store.startTranscriptAnalysis(video: video) }
                    .buttonStyle(.borderedProminent)
                    .disabled(rows.isEmpty)
                Text("Runs on this Mac in a few seconds. No AI call.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var working: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(analysisJob?.statusLine.isEmpty == false ? analysisJob?.statusLine ?? "" : "Finding topics, pauses, and filler…")
                    .lineLimit(1).truncationMode(.tail)
            }
            if let job = analysisJob {
                Button("Stop") { store.jobs.cancel(job.id) }
            }
            Text("Keeps going if you close this window; the status bar shows it.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var list: some View {
        let shown = shown
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if shown.isEmpty {
                        Text(stateFilter == .pending ? "Every cut is decided." : "No cuts here.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    ForEach(shown) { cut in
                        VStack(spacing: 0) {
                            row(cut, shown: shown)
                            if focusedID == cut.id { detail(cut) }
                            Divider()
                        }
                        .id(cut.id)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
                move(forward: press.key == .downArrow, extending: press.modifiers.contains(.shift), proxy: proxy)
                return .handled
            }
            .onKeyPress(.space) { auditionFocused(); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "cCkK"), phases: .down) { press in
                // Command-C and the like are not decisions.
                guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
                decideFocused(press.characters.lowercased() == "c" ? .accepted : .rejected, proxy: proxy)
                return .handled
            }
            .onAppear { listFocused = true }
        }
    }

    private func row(_ cut: EditProposal, shown: [EditProposal]) -> some View {
        let focused = focusedID == cut.id
        let selected = selection.contains(cut.id)
        let auditioning = audition.cutID == cut.id
        let context = contexts[cut.id] ?? .init()
        return HStack(spacing: 10) {
            Button {
                focus(cut.id)
                play(cut)
            } label: {
                Image(systemName: auditioning ? "stop.fill" : "play.fill")
                    .font(.system(size: 9))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(auditioning ? Color.white : Color.primary)
                    .background(auditioning ? Color.accentColor : Color.secondary.opacity(0.25), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(auditioning ? "Stop" : "Hear this cut")
            .help("Hear the second before the cut, then the second after it, as if the cut were made")

            HStack(spacing: 6) {
                Circle().fill(Self.color(cut.kind)).frame(width: 7, height: 7)
                Text(cut.kind.label).lineLimit(1)
            }
            .frame(width: 116, alignment: .leading)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(CleanupCutReview.timecode(cut.startTime)).foregroundStyle(.secondary)
                Text(Self.seconds(cut.endTime - cut.startTime)).font(.caption).foregroundStyle(.tertiary)
            }
            .monospacedDigit().lineLimit(1)
            .frame(width: 104, alignment: .leading)

            contextText(context, cut: cut, strong: focused)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(cut.reason)

            decisionControl(cut)
        }
        .padding(.horizontal).frame(height: 36)
        .opacity(cut.decision == .pending || focused ? 1 : 0.62)
        .background(focused ? Color.accentColor.opacity(0.18) : selected ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { tapped(cut.id, shown: shown) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(cut.kind.label) at \(CleanupCutReview.timecode(cut.startTime)), \(Self.decisionWord(cut.decision))\(selected ? ", selected" : "")")
        .accessibilityAction(named: selected ? "Remove from Selection" : "Add to Selection") {
            if selected { selection.remove(cut.id) } else { selection.insert(cut.id) }
        }
    }

    /// "…before [removed] after…": the removed words struck through, a
    /// silence shown as its length.
    private func contextText(_ context: CleanupCutReview.Context, cut: EditProposal, strong: Bool) -> Text {
        guard !context.isEmpty else { return Text(cut.reason).foregroundStyle(.secondary) }
        var before = AttributedString(context.before.isEmpty ? "" : "…\(context.before) ")
        before.foregroundColor = strong ? .primary : .secondary
        var removed = AttributedString(context.removed.isEmpty ? "⏸ \(Self.seconds(cut.endTime - cut.startTime))" : context.removed)
        removed.foregroundColor = .pink
        removed.backgroundColor = Color.pink.opacity(0.14)
        if !context.removed.isEmpty { removed.strikethroughStyle = .single }
        var after = AttributedString(context.after.isEmpty ? "" : " \(context.after)…")
        after.foregroundColor = strong ? .primary : .secondary
        return Text(before + removed + after)
    }

    private func decisionControl(_ cut: EditProposal) -> some View {
        HStack(spacing: 0) {
            decisionButton("Cut", on: cut.decision == .accepted, tint: .pink) {
                focus(cut.id)
                decide(CleanupCutReview.toggled(cut.decision, to: .accepted), ids: [cut.id])
            }
            .help(cut.decision == .accepted ? "Cut. Click again to leave it undecided" : "Remove this from the footage")
            Divider().frame(height: 22)
            decisionButton("Keep", on: cut.decision == .rejected, tint: .green) {
                focus(cut.id)
                decide(CleanupCutReview.toggled(cut.decision, to: .rejected), ids: [cut.id])
            }
            .help(cut.decision == .rejected ? "Kept. Click again to leave it undecided" : "Leave this in the footage")
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.4)))
        .fixedSize()
    }

    private func decisionButton(_ title: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // The checkmark carries the state without relying on colour.
            HStack(spacing: 3) {
                if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                Text(title).font(.callout.weight(on ? .semibold : .regular)).lineLimit(1)
            }
            .frame(width: 58, height: 22)
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .background(on ? tint.opacity(0.28) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The selected row's frame and its edges, a twentieth of a second per step.
    private func detail(_ cut: EditProposal) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VideoThumbnail(url: video.url, time: (cut.startTime + cut.endTime) / 2, cornerRadius: 6)
                .frame(width: 128, height: 72)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    edge("From", time: cut.startTime, help: "Where the cut starts") { nudge(cut, start: $0) }
                    edge("To", time: cut.endTime, help: "Where the cut ends") { nudge(cut, end: $0) }
                    Text("removes \(Self.seconds(cut.endTime - cut.startTime))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).fixedSize()
                }
                Text("\(cut.reason). Move an edge if the cut clips a word, then hear it again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 48).padding(.trailing).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.10))
    }

    private func edge(_ label: String, time: Double, help: String, step: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(Self.fineTimecode(time)).monospacedDigit()
            Stepper(label, onIncrement: { step(0.05) }, onDecrement: { step(-0.05) })
                .labelsHidden()
        }
        .lineLimit(1).fixedSize()
        .help(help + "; each step is a twentieth of a second")
    }

    // MARK: - Actions

    private func load() async {
        guard let database = store.database else { isLoading = false; return }
        let loadedRows = ((try? await database.fetchTranscripts(videoID: video.id)) ?? []).filter { !$0.isTranslation }
        let loadedCuts = CleanupCutReview.cuts((try? await database.fetchEditProposals(videoID: video.id)) ?? [])
        let features = (try? await database.fetchTranscriptFeatures(videoID: video.id)) ?? []
        let loadedContexts = await Self.contexts(cuts: loadedCuts, rows: loadedRows)
        guard !Task.isCancelled else { return }
        rows = loadedRows
        cuts = loadedCuts
        contexts = loadedContexts
        analyzed = !features.isEmpty || !loadedCuts.isEmpty
        // A fresh analysis gives the cuts new ids.
        let ids = Set(loadedCuts.map(\.id))
        selection.formIntersection(ids)
        sticky.formIntersection(ids)
        if let focusedID, !ids.contains(focusedID) { self.focusedID = nil }
        dropMissingKind()
        isLoading = false
    }

    /// Hundreds of cuts over thousands of words: off the main actor.
    @concurrent
    private nonisolated static func contexts(cuts: [EditProposal], rows: [TranscriptRow]) async -> [Int64: CleanupCutReview.Context] {
        cuts.reduce(into: [:]) { result, cut in
            // Only the lines near the cut can hold its words.
            let near = rows.filter { $0.endTime >= cut.startTime - 30 && $0.startTime <= cut.endTime + 30 }
            result[cut.id] = CleanupCutReview.context(for: cut, rows: near)
        }
    }

    /// A kind with no cut under the state on show has no chip to turn it off.
    private func dropMissingKind() {
        guard let kind = kindFilter else { return }
        if !CleanupCutReview.kinds(cuts, state: stateFilter, sticky: sticky).contains(where: { $0.kind == kind }) {
            kindFilter = nil
        }
    }

    private func filterChanged() {
        sticky = []
        selection = []
        anchorID = nil
        dropMissingKind()
        if let focusedID, !shown.contains(where: { $0.id == focusedID }) {
            audition.stop()
            self.focusedID = nil
        }
    }

    private func focus(_ id: Int64) {
        if focusedID != id, audition.isPlaying { audition.stop() }
        focusedID = id
        listFocused = true
    }

    /// A click selects the row; Shift takes the run from the last row, Command adds or removes one.
    private func tapped(_ id: Int64, shown: [EditProposal]) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift) {
            selection = CleanupCutReview.range(from: anchorID ?? focusedID, to: id, in: shown)
        } else if modifiers.contains(.command) {
            if selection.isEmpty, let focusedID { selection.insert(focusedID) }
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = []
        }
        if !modifiers.contains(.shift) { anchorID = id }
        focus(id)
    }

    /// Shift keeps the row the run started at and selects through to the new one.
    private func move(forward: Bool, extending: Bool, proxy: ScrollViewProxy) {
        let listed = shown
        guard let next = CleanupCutReview.neighbour(of: focusedID, in: listed, forward: forward) else { return }
        if extending {
            if anchorID == nil { anchorID = focusedID ?? next }
            selection = CleanupCutReview.range(from: anchorID, to: next, in: listed)
        } else {
            selection = []
            anchorID = next
        }
        focus(next)
        proxy.scrollTo(next)
    }

    private func auditionFocused() {
        guard let cut = cuts.first(where: { $0.id == focusedID }) else { return }
        play(cut)
    }

    private func play(_ cut: EditProposal) {
        guard video.isPresent else { return }
        audition.audition(url: video.url, cut: cut.startTime...max(cut.startTime, cut.endTime), id: cut.id)
    }

    /// C or K on the focused row, then on to the next undecided one.
    private func decideFocused(_ decision: EditProposal.Decision, proxy: ScrollViewProxy) {
        guard let focusedID, cuts.contains(where: { $0.id == focusedID }) else { return }
        let listed = shown
        decide(decision, ids: [focusedID])
        guard let index = listed.firstIndex(where: { $0.id == focusedID }),
              let next = listed[(index + 1)...].first(where: { $0.decision == .pending }) else { return }
        anchorID = next.id
        focus(next.id)
        proxy.scrollTo(next.id)
    }

    /// The list changes at once; the write follows, all or none, and a
    /// failed write puts the earlier decisions back.
    private func decide(_ decision: EditProposal.Decision, ids: Set<Int64>) {
        guard let database = store.database, !ids.isEmpty else { return }
        let before = cuts.filter { ids.contains($0.id) }.reduce(into: [Int64: EditProposal.Decision]()) { $0[$1.id] = $1.decision }
        for index in cuts.indices where ids.contains(cuts[index].id) { cuts[index].decision = decision }
        sticky.formUnion(ids)
        if ids.count > 1 { selection = [] }
        Task {
            do {
                try await database.setEditProposalDecisions(ids: ids, decision: decision)
            } catch {
                for index in cuts.indices {
                    // Only where nothing newer was decided meanwhile.
                    if let old = before[cuts[index].id], cuts[index].decision == decision { cuts[index].decision = old }
                }
                store.presentError("Could not save cut decisions", error)
            }
        }
    }

    private func nudge(_ cut: EditProposal, start: Double = 0, end: Double = 0) {
        guard let database = store.database, let index = cuts.firstIndex(where: { $0.id == cut.id }) else { return }
        let moved = CleanupCutReview.nudged(cuts[index], start: start, end: end, duration: video.duration)
        guard moved != cuts[index] else { return }
        let old = cuts[index]
        audition.stop()
        cuts[index] = moved
        contexts[moved.id] = context(moved)
        Task {
            do {
                try await database.updateEditProposal(moved)
            } catch {
                // The edges go back unless a later nudge moved them again;
                // a decision made meanwhile stays.
                if let index = cuts.firstIndex(where: { $0.id == moved.id }),
                   cuts[index].startTime == moved.startTime, cuts[index].endTime == moved.endTime {
                    cuts[index].startTime = old.startTime
                    cuts[index].endTime = old.endTime
                    contexts[moved.id] = context(cuts[index])
                }
                store.presentError("Could not save the cut", error)
            }
        }
    }

    private func context(_ cut: EditProposal) -> CleanupCutReview.Context {
        CleanupCutReview.context(for: cut, rows: rows.filter { $0.endTime >= cut.startTime - 30 && $0.startTime <= cut.endTime + 30 })
    }

    // MARK: - Wording

    private static func seconds(_ length: Double) -> String {
        "\(max(0, length).formatted(.number.precision(.fractionLength(1)))) s"
    }

    /// Hundredths, for the edges being nudged.
    private static func fineTimecode(_ seconds: Double) -> String {
        let hundredths = Int((max(0, seconds) * 100).rounded())
        return String(format: "%d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }

    private static func decisionWord(_ decision: EditProposal.Decision) -> String {
        switch decision {
        case .pending: "not decided"
        case .accepted: "cut"
        case .rejected: "kept"
        }
    }

    static func color(_ kind: EditProposal.Kind) -> Color {
        switch kind {
        case .silence: .blue
        case .filler: .orange
        case .repeatWord: .purple
        case .falseStart: .teal
        case .retake: .green
        case .noise: .yellow
        case .plannedClip, .bRoll, .photo: .gray
        }
    }
}
