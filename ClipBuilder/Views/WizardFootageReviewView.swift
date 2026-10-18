import SwiftUI

/// The Wizard's saved selections and takes reviewed on the page, the way
/// Express reviews its candidates: watch a cut, drag its start and end, keep
/// the take that should render, ask for another take, rename or delete.
struct WizardFootageReviewView: View {
    @Environment(AppStore.self) private var store
    let selections: [WizardSelectionSummary]
    let options: WizardOptions
    @State private var rows: [TranscriptRow] = []
    @State private var labels: [Int64: String] = [:]
    @State private var transcriptError: String?
    @State private var notes: [Int64: String] = [:]
    @State private var selectedTakeID: Int64?

    private var scenes: [SceneRecord] {
        SceneReferences.combining(store.referencedScenes, referenced: store.historyScenes)
    }

    private var items: [RangeReviewItem] {
        WizardFootageReview.items(selections: selections, scenes: scenes, videos: store.videos)
    }

    private var videoIDs: [Int64] {
        Set(items.flatMap { $0.children.isEmpty ? [$0.video.id] : $0.children.map { $0.video.id } }).sorted()
    }

    private var kept: Binding<Set<Int64>> {
        Binding(get: { WizardFootageReview.keptIDs(selections) }, set: { kept in
            guard !store.isWizardRunning else { return }
            for change in WizardFootageReview.bestTakeChanges(from: kept, in: selections) {
                store.setBestWizardTake(selectionID: change.selectionID, takeID: change.takeID)
            }
        })
    }

    private var selection: Binding<Int64?> {
        Binding(get: { selectedTakeID ?? selections.first?.bestTake?.id }, set: { id in
            selectedTakeID = id
            if let id, let (summary, _) = WizardFootageReview.take(.init(ownerID: id), in: selections) {
                store.activeWizardSelectionID = summary.id
            }
        })
    }

    var body: some View {
        RangeReviewView(items: items, rows: rows, labels: labels, kept: kept,
                        preferredTranslationLanguage: store.activeProfile.captionLanguages.first,
                        selection: selection, emptyTitle: "Select a take",
                        emptyMessage: "Choose a take to watch it and adjust its cuts.",
                        resetTitle: "Reset to Suggested", playAll: true, onSave: save) { item in
            if let (summary, take) = WizardFootageReview.take(item.id, in: selections) {
                footer(summary, take: take, available: item.isAvailable)
            }
        }
        .task(id: videoIDs) { await loadTranscript() }
    }

    private func save(_ item: RangeReviewItem, start: Double, end: Double) {
        guard let (_, take) = WizardFootageReview.take(item.id, in: selections),
              let plan = WizardFootageReview.trimming(item.id, to: start...max(start, end), take: take, scenes: scenes)
        else { return }
        store.saveWizardTakePlan(plan, takeID: take.id)
    }

    private func footer(_ summary: WizardSelectionSummary, take: WizardSelectionTake, available: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(spacing: Theme.spaceS) {
                TextField("Selection name", text: Binding(
                    get: { summary.selection.name },
                    set: { store.renameWizardSelection(summary.id, name: $0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Selection name")
                Button("Delete selection", systemImage: "trash") { store.deleteWizardSelection(summary.id) }
                    .labelStyle(.iconOnly).help("Delete this selection and its takes")
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceS) {
                    noteField(summary).frame(minWidth: 160)
                    anotherTakeButton(summary)
                    modelButton
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    noteField(summary)
                    HStack(spacing: Theme.spaceS) {
                        anotherTakeButton(summary)
                        modelButton
                    }
                }
            }
            if !available {
                FormCaption("Footage changed. Ask for another take to plan from the current analysis.", tone: .warning)
            }
            if let transcriptError { FormCaption(transcriptError, tone: .warning) }
        }
        .disabled(store.isWizardRunning)
    }

    private var modelButton: some View {
        MiniModelButton(tasks: [options.formatPreset == ReelRecipe.podcastHighlights.id ? "highlights" : "wizard"])
    }

    private func noteField(_ summary: WizardSelectionSummary) -> some View {
        TextField("What should change in the next take?", text: Binding(
            get: { notes[summary.id] ?? "" }, set: { notes[summary.id] = $0 }))
            .textFieldStyle(.roundedBorder)
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            .onSubmit { anotherTake(summary) }
            .accessibilityLabel("What should change in the next take of \(summary.selection.name)?")
    }

    private func anotherTakeButton(_ summary: WizardSelectionSummary) -> some View {
        Button { anotherTake(summary) } label: {
            Label("Another take", systemImage: "arrow.trianglehead.2.clockwise").lineLimit(1).fixedSize()
        }
        .accessibilityLabel("Another take of \(summary.selection.name)")
    }

    private func anotherTake(_ summary: WizardSelectionSummary) {
        guard !store.isWizardRunning else { return }
        store.findWizardMoments(options: options, selectionID: summary.id, note: notes[summary.id] ?? "",
                                presentReview: false)
    }

    private func loadTranscript() async {
        guard let database = store.database else { return }
        let generation = store.profileGeneration
        let ids = videoIDs
        rows = []
        labels = [:]
        transcriptError = nil
        do {
            var loadedRows: [TranscriptRow] = []
            var loadedLabels: [Int64: String] = [:]
            for id in ids {
                let videoRows = try await database.fetchTranscripts(videoID: id)
                let speakers = await store.speakerTurns(videoID: id)
                try Task.checkCancellation()
                guard generation == store.profileGeneration else { return }
                let people = store.people
                let labelTask = Task.detached { () throws -> [Int64: String] in
                    var result: [Int64: String] = [:]
                    for row in videoRows {
                        try Task.checkCancellation()
                        result[row.id] = TranscriptSpeakers.label(for: row, turns: speakers.turns,
                                                                 roster: speakers.roster, people: people)
                    }
                    return result
                }
                let videoLabels = try await withTaskCancellationHandler {
                    try await labelTask.value
                } onCancel: {
                    labelTask.cancel()
                }
                try Task.checkCancellation()
                guard generation == store.profileGeneration else { return }
                loadedRows.append(contentsOf: videoRows)
                loadedLabels.merge(videoLabels, uniquingKeysWith: { first, _ in first })
            }
            rows = loadedRows
            labels = loadedLabels
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == store.profileGeneration else { return }
            transcriptError = "Could not load the transcript. Reopen Footage to try again."
        }
    }
}
