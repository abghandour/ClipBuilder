import SwiftUI

struct FightActionDetailSheet: View {
    let video: VideoRecord
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var playback = FightActionPlayback()
    @State private var model = FightActionDetail.Model()
    @State private var rounds: [FightRoundRange] = []
    @State private var round: Int?
    @State private var fighter: String?
    @State private var category = "All"
    @State private var corrections: [FightCorrectionRecord] = []
    @State private var roster: [VideoPersonRecord] = []
    @State private var adding: FightEventRecord?
    @State private var removed: FightCorrectionRecord?
    @State private var reviewError: String?
    /// The action to select again once the list is rebuilt after a save.
    @State private var reselect: FightEventRecord?
    @State private var showingRetry = false
    @State private var retryScope = FightCorrections.RetryScope.wholeFight
    @State private var highlights: [StrikeHighlightRecord] = []

    private nonisolated struct Input: Equatable, Sendable {
        var events: [FightEventRecord]
        var people: [PersonRecord]
        var scenes: [SceneRecord]
        var research: String?
        var round: Int?
    }
    private var input: Input {
        .init(events: store.fightEvents[video.id] ?? [], people: store.people,
              scenes: store.scenes.filter { $0.videoID == video.id },
              research: store.fightResearch[video.id]?.summaryJSON, round: round)
    }
    private var range: ClosedRange<Double> {
        let spans = rounds.filter { $0.round == round }
        return (spans.map(\.start).min() ?? 0)...max(1, spans.map(\.end).max() ?? video.duration)
    }
    private var visibleRows: [FightActionDetail.Row] {
        guard category != "Removed" else { return [] }
        return model.rows.filter { row in
            (fighter == nil || row.event.fighterKey == fighter) &&
                (category == "All" || (category == "Significant" && ["significant_strike", "hurt", "knockdown"].contains(row.event.action))
                 || (category == "Takedowns" && ["takedown", "takedown_attempt"].contains(row.event.action)))
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            if store.fightScoringInFlight.contains(video.id) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Fight scoring is running. You can close this window; Stop is in the job row.")
                        .font(.caption).lineLimit(1).fixedSize()
                    Spacer()
                }
            }
            if let result = store.fightRetryResults[video.id] {
                HStack {
                    Text(result).font(.caption).lineLimit(1).truncationMode(.tail)
                        .help(result)
                    Spacer()
                    Button("AI Lessons", systemImage: "graduationcap") {
                        store.selectSection(.learned)
                        dismiss()
                    }.lineLimit(1).fixedSize()
                }.fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 16) {
                    scoreboard
                    graph
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 12) {
                            FightActionPreview(playback: playback,
                                hdTrack: playback.selected.flatMap { savedTrack(for: $0.event) },
                                hdBusy: store.fightScoringInFlight.contains(video.id) || !video.isLocal,
                                hdWorking: playback.selected.map { becomingHD($0.event) } ?? false,
                                makeHD: {
                                    if let event = playback.selected?.event { makeHD([event]) }
                                })
                            // The row as listed, and only while its saved row is still there.
                            if let event = adding ?? playback.selected.flatMap({ selected in
                                input.events.contains(selected.stored) ? selected.event : nil
                            }) {
                                FightActionEditor(event: event, stored: adding == nil ? playback.selected?.stored : nil,
                                    correction: correction(for: event), adding: adding != nil,
                                    roster: roster, people: store.people, playback: playback, duration: video.duration,
                                    onSaved: { await reviewSaved(keeping: adding == nil ? event : nil) })
                                    // The saved values are part of the identity: an Undo
                                    // changes the row in place, and the editor must start
                                    // again from what is saved, not keep its draft.
                                    .id("\(event.id)|\(event.generation ?? 0)|\(adding != nil)|" + (adding != nil ? "" : "\(event.time)|\(event.fighterKey)|\(event.action)|\(event.detail ?? "")|\(event.endTime ?? -1)|\(event.outcome ?? "")|\(event.targetKey ?? "")"))
                            } else if let removed {
                                Text("Removed action").font(.headline)
                                Text(removed.original.map { FightActionDetail.build(events: [$0], people: store.people).rows.first?.sentence ?? $0.action } ?? "Action")
                                    .strikethrough()
                                Button("Undo correction") { undoRemoved(removed) }.lineLimit(1).fixedSize()
                            }
                            if let reviewError { Text(reviewError).foregroundStyle(.red).font(.caption) }
                        }.frame(width: 420)
                        actionList
                    }
                    FightActionBreakdown(model: model)
                }.padding(.horizontal, 4)
            }
        }
        .padding(20)
        .frame(minWidth: 1100, idealWidth: 1180, maxWidth: .infinity,
               minHeight: 820, idealHeight: 900, maxHeight: .infinity)
        .task { await playback.open(video: video) }
        .task(id: input) { await rebuild() }
        .task(id: store.strikeHighlightRevision) { await loadHighlights() }
        .onChange(of: store.profileGeneration) { playback.close(); dismiss() }
        .onChange(of: store.strikeHighlightRevision) { playback.refreshHighlight(video: video, store: store) }
        .onDisappear { playback.close() }
    }

    private var header: some View {
        HStack {
            Text("Fight Action").font(.title2.bold())
            Text(store.fightResearch[video.id]?.fightLabel ?? video.filename).foregroundStyle(.secondary)
            Text("\(video.duration.timecode) · scored v\(input.events.compactMap(\.scoringVersion).min() ?? 1)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(corrections.count) corrections").font(.caption)
            Picker("Scope", selection: $round) {
                Text("Whole fight").tag(Int?.none)
                ForEach(Array(Set(rounds.map(\.round))).sorted(), id: \.self) { value in
                    Text("R\(value)").tag(Optional(value))
                }
            }.frame(width: 170)
            Button("Retry…") { showingRetry = true }
                .lineLimit(1).fixedSize()
                .disabled(store.fightScoringInFlight.contains(video.id))
                .popover(isPresented: $showingRetry) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Score again using your \(corrections.count) corrections").font(.headline)
                            .lineLimit(1).fixedSize()
                        Picker("Retry scope", selection: $retryScope) {
                            ForEach(FightCorrections.RetryScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.lineLimit(1).fixedSize()
                        Text("Scores the whole fight, including attempts that cross sampling windows.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Start retry") {
                            playback.pause()
                            showingRetry = false
                            store.retryFightScoring(video: video, scope: retryScope)
                        }.lineLimit(1).fixedSize()
                            .disabled(store.fightScoringInFlight.contains(video.id))
                    }.padding().frame(width: 380)
                }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }.lineLimit(1).fixedSize(horizontal: false, vertical: true)
    }

    private var scoreboard: some View {
        HStack(spacing: 20) {
            ForEach(Array(model.fighters.enumerated()), id: \.element.id) { index, fighter in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(fighter.points, format: .number).font(.title.bold())
                        Text(fighter.name).font(.headline)
                        Spacer()
                        Text(fighter.share, format: .percent.precision(.fractionLength(0)))
                    }.lineLimit(1).fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: fighter.share).tint(color(fighter.id, index: index))
                    Text(FightScoreDigest.line(fighter.counts, name: fighter.name)).font(.caption)
                }.frame(maxWidth: .infinity)
            }
        }
    }

    private var graph: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Momentum").font(.headline).lineLimit(1).fixedSize()
            FightGraphView(events: model.rows.map(\.event), range: range, people: store.people,
                           height: 150, showsLegend: false, fighterKeys: model.fighters.map(\.id).filter { !$0.isEmpty }, onSeek: seek, markerTime: playback.time)
                .overlay {
                    GeometryReader { geometry in
                        Canvas { context, size in
                            let span = max(1, range.upperBound - range.lowerBound)
                            for boundary in rounds where range.contains(boundary.start) {
                                let x = (boundary.start - range.lowerBound) / span * size.width
                                var path = Path()
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: size.height))
                                context.stroke(path, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            }
                            for row in model.markers {
                                let index = model.fighters.firstIndex { $0.id == row.event.fighterKey } ?? 2
                                let y = row.event.fighterKey.isEmpty ? size.height / 2 : (index == 0 ? 12.0 : size.height - 12)
                                let x = (row.event.time - range.lowerBound) / span * size.width
                                context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)),
                                             with: .color(color(row.event.fighterKey, index: index)))
                            }
                        }.frame(width: geometry.size.width, height: geometry.size.height)
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
        }
    }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Actions · \(category == "Removed" ? removedCorrections.count : visibleRows.count)").font(.headline)
                Button("HD for all", systemImage: "sparkles.rectangle.stack") { makeHD(plainStrikes) }
                    .lineLimit(1).fixedSize()
                    .disabled(plainStrikes.isEmpty || store.fightScoringInFlight.contains(video.id) || !video.isLocal)
                    .help("Follow the limb's outline for every strike in this video that has a plain highlight.")
                Picker("Fighter", selection: $fighter) {
                    Text("All fighters").tag(String?.none)
                    ForEach(model.fighters) { Text($0.name).tag(Optional($0.id)) }
                }
            }.lineLimit(1).fixedSize(horizontal: false, vertical: true)
            Picker("Actions", selection: $category) {
                ForEach(["All", "Significant", "Takedowns", "Removed"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented).lineLimit(1).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(visibleRows) { row in
                        HStack(spacing: 4) {
                        Button { select(row) } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.event.time.timecode)
                                    .monospacedDigit().frame(width: 58, alignment: .trailing)
                                VStack(alignment: .leading) {
                                    Text(row.sentence)
                                    Text(row.impact).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if becomingHD(row.event) {
                                    ProgressView().controlSize(.small)
                                        .help("Making the HD highlight")
                                        .accessibilityLabel("Making the HD highlight")
                                }
                                if savedTrack(for: row.event)?.isHD == true {
                                    Text("HD").font(.caption2.bold()).lineLimit(1).fixedSize()
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                        .accessibilityLabel("HD highlight")
                                }
                                if let correction = correction(for: row.event) {
                                    Image(systemName: correction.kind == .confirm ? "checkmark" : "pencil")
                                        .accessibilityLabel(correction.kind == .confirm ? "Confirmed" : "Corrected")
                                }
                                Text("+\(row.points.formatted())").monospacedDigit()
                            }
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(playback.selected?.id == row.id ? Color.accentColor.opacity(0.15) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button("Not an action", systemImage: "trash") { remove(row) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .help("Not an action: remove it from the count. It stays under Removed, where it can be brought back.")
                            .disabled(store.fightScoringInFlight.contains(video.id))
                        }
                    }
                    if category == "Removed" {
                        ForEach(removedCorrections) { correction in
                            Button {
                                adding = nil
                                removed = correction
                                if let original = correction.original {
                                    playback.seekFreely(to: original.time)
                                }
                            } label: {
                                Text(correction.original.flatMap {
                                    FightActionDetail.build(events: [$0], people: store.people).rows.first?.sentence
                                } ?? "Removed action")
                                    .strikethrough().padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    } else if visibleRows.isEmpty { Text("No actions in this scope").foregroundStyle(.secondary).padding() }
                }
            }.frame(height: 340)
            Button("Add action at playhead", systemImage: "plus") {
                playback.clearAction()
                removed = nil
                adding = FightEventRecord(id: 0, videoID: video.id, time: playback.time, fighterKey: roster.first?.key ?? "",
                    action: "strike", points: 1, scoringVersion: 3)
            }.lineLimit(1).fixedSize().disabled(store.fightScoringInFlight.contains(video.id))
        }.frame(maxWidth: .infinity)
    }

    private func color(_ key: String, index: Int) -> Color { key.isEmpty ? .gray : index == 0 ? .red : .cyan }

    private func seek(_ time: Double) {
        if let row = model.rows.min(by: { abs($0.event.time - time) < abs($1.event.time - time) }), abs(row.event.time - time) <= 1 {
            select(row)
            playback.seek(to: time, play: true)
        } else { playback.seekFreely(to: time); adding = nil; removed = nil }
    }

    private func rebuild() async {
        let input = input, duration = video.duration
        // The fight's saved result: a finished submission is counted as done
        // only when it agrees with it.
        let outcomes = (try? await store.database?.fetchOutcomes()) ?? []
        let result = await Task.detached(priority: .userInitiated) {
            let rounds = FightActionDetail.rounds(scenes: input.scenes, researchJSON: input.research, duration: duration)
            return (rounds, FightActionDetail.build(events: input.events, people: input.people, rounds: rounds, round: input.round,
                                                    outcomes: outcomes))
        }.value
        guard !Task.isCancelled else { return }
        rounds = result.0
        model = result.1
        let keep = reselect ?? playback.selected?.event
        playback.clearAction()
        adding = nil
        removed = nil
        await loadReviews()
        await loadHighlights()
        reselect = keep
        restoreSelection()
    }

    private func select(_ row: FightActionDetail.Row) {
        adding = nil
        removed = nil
        playback.select(row, video: video, store: store)
    }

    private func savedTrack(for event: FightEventRecord) -> StrikeHighlightRules.Track? {
        guard StrikeStatsSummary.strikeFamily.contains(event.action) else { return nil }
        return highlights.first { $0.matches(time: event.time, fighterKey: event.fighterKey) }?.track
    }

    private var plainStrikes: [FightEventRecord] {
        input.events.filter { event in savedTrack(for: event).map { !$0.isHD } ?? false }
    }

    private func makeHD(_ events: [FightEventRecord]) {
        // The popup stays: the rows being worked on spin until each is saved.
        store.makeStrikeHighlightsHD(video: video, events: events)
    }

    /// An HD job is working on this action's highlight and has not saved it yet.
    private func becomingHD(_ event: FightEventRecord) -> Bool {
        store.strikeHighlightsBecomingHD[video.id]?.contains(event.id) == true && savedTrack(for: event)?.isHD != true
    }

    private func loadHighlights() async {
        guard let database = store.database else { highlights = []; return }
        let profile = store.profileGeneration, revision = store.strikeHighlightRevision
        do {
            let saved = try await database.fetchStrikeHighlights(videoID: video.id)
            guard !Task.isCancelled, profile == store.profileGeneration, store.database === database,
                  revision == store.strikeHighlightRevision else { return }
            highlights = saved
        } catch {
            guard !Task.isCancelled, profile == store.profileGeneration else { return }
            highlights = []
            reviewError = error.localizedDescription
            ErrorLog.record("Load HD strike highlights", error.localizedDescription)
        }
    }

    private func correction(for event: FightEventRecord) -> FightCorrectionRecord? {
        corrections.first { $0.eventID == event.id && $0.generation == event.generation }
    }

    private var removedCorrections: [FightCorrectionRecord] {
        corrections.filter { correction in
            guard correction.kind == .remove, fighter == nil || correction.fighterKey == fighter else { return false }
            guard let round else { return true }
            return rounds.contains { $0.round == round && correction.time >= $0.start && correction.time < $0.end }
        }
    }

    private func loadReviews() async {
        guard let database = store.database else { return }
        let profile = store.profileGeneration
        do {
            let saved = try await database.fetchFightCorrections(videoID: video.id)
            let roster = try await database.fetchVideoPeople(videoID: video.id)
            guard !Task.isCancelled, profile == store.profileGeneration else { return }
            corrections = saved
            self.roster = roster
        } catch {
            guard !Task.isCancelled, profile == store.profileGeneration else { return }
            reviewError = error.localizedDescription
            ErrorLog.record("Load Fight Action corrections", error.localizedDescription)
        }
    }

    /// After a saved review. `keeping` is the action to stay on, so its
    /// highlight is found again for what it is now and shown at once.
    private func reviewSaved(keeping event: FightEventRecord? = nil) async {
        playback.clearAction()
        adding = nil
        removed = nil
        reselect = event
        await loadReviews()
        // Nothing about the events changed (a confirmation): no rebuild will come.
        if !Task.isCancelled, input.events == model.rows.map(\.event) || model.rows.map(\.event).allSatisfy(input.events.contains) {
            restoreSelection()
        }
    }

    private func restoreSelection() {
        guard let wanted = reselect else { return }
        reselect = nil
        if let row = FightActionDetail.row(for: wanted, in: model.rows) { select(row) }
    }

    private func remove(_ row: FightActionDetail.Row) {
        if playback.selected?.id == row.id { playback.clearAction() }
        Task {
            do { try await store.removeFightEvent(row.stored); await loadReviews() }
            catch { reviewError = error.localizedDescription }
        }
    }

    private func undoRemoved(_ correction: FightCorrectionRecord) {
        Task {
            do { try await store.undoFightCorrection(correction); await reviewSaved() }
            catch { reviewError = error.localizedDescription }
        }
    }
}
