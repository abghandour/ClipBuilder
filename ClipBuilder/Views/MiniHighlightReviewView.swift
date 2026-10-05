import SwiftUI

/// Mini's finder and planner takes adapt to the same review as Q&A.
struct MiniHighlightReviewView: View {
    @Environment(AppStore.self) private var store
    let run: MiniWizardRun
    @State private var rows: [TranscriptRow] = []
    @State private var labels: [Int64: String] = [:]
    @State private var transcriptError: String?

    private var items: [RangeReviewItem] {
        MiniHighlightReview.items(candidates: run.candidates, video: run.video, scenes: store.scenes)
    }

    private var videoIDs: [Int64] {
        Set(items.flatMap { $0.children.isEmpty ? [$0.video.id] : $0.children.map { $0.video.id } }).sorted()
    }

    private var kept: Binding<Set<Int64>> {
        Binding(get: {
            guard let current = store.miniRun, current.batchID == run.batchID else { return [] }
            return MiniHighlightReview.keptIDs(current.candidates)
        }, set: { kept in
            guard let current = store.miniRun, current.batchID == run.batchID, !store.isWizardRunning else { return }
            store.miniRun?.candidates = MiniHighlightReview.settingKept(kept, in: current.candidates)
        })
    }

    private var selection: Binding<Int64?> {
        Binding(get: {
            store.miniRun?.batchID == run.batchID ? store.miniRun?.selectedSelectionID : nil
        }, set: { selected in
            guard store.miniRun?.batchID == run.batchID else { return }
            store.miniRun?.selectedSelectionID = selected
        })
    }

    var body: some View {
        RangeReviewView(items: items, rows: rows, labels: labels, kept: kept,
                        preferredTranslationLanguage: store.activeProfile.captionLanguages.first,
                        selection: selection, emptyTitle: "Select a candidate",
                        emptyMessage: "Choose a candidate to watch it and adjust its cuts.",
                        resetTitle: "Reset to Suggested", onSave: save) { item in
            if let candidate = run.candidates.first(where: { $0.id == item.id.ownerID }) {
                regenerateRow(candidate, available: item.isAvailable)
            }
        }
        .task(id: videoIDs) { await loadTranscript() }
    }

    private func save(_ item: RangeReviewItem, start: Double, end: Double) {
        guard let current = store.miniRun, current.batchID == run.batchID,
              let candidate = current.candidates.first(where: { $0.id == item.id.ownerID }),
              let plan = MiniHighlightReview.trimming(item.id, to: start...max(start, end),
                                                      candidate: candidate, scenes: store.scenes) else { return }
        store.saveMiniCandidatePlan(plan, selectionID: candidate.id, takeID: candidate.take.id)
    }

    private func regenerateRow(_ candidate: MiniWizardCandidate, available: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceS) {
                    noteField(candidate).frame(minWidth: 160)
                    regenerateButton(candidate)
                    modelButton
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    noteField(candidate)
                    HStack(spacing: Theme.spaceS) {
                        regenerateButton(candidate)
                        modelButton
                    }
                }
            }
            if !available {
                FormCaption("Footage changed. Regenerate this candidate to use the current analysis.", tone: .warning)
            }
            if let transcriptError { FormCaption(transcriptError, tone: .warning) }
        }
    }

    /// Regenerate asks the same model that found the candidates.
    private var modelButton: some View {
        MiniModelButton(tasks: [run.options.formatPreset == ReelRecipe.podcastHighlights.id ? "highlights" : "wizard"])
    }

    private func noteField(_ candidate: MiniWizardCandidate) -> some View {
        TextField("What should change?", text: Binding(
            get: { currentCandidate(candidate.id)?.note ?? candidate.note },
            set: { note in
                guard store.miniRun?.batchID == run.batchID, !store.isWizardRunning,
                      let index = store.miniRun?.candidates.firstIndex(where: { $0.id == candidate.id }) else { return }
                store.miniRun?.candidates[index].note = note
            }))
            .textFieldStyle(.roundedBorder)
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            .disabled(store.isWizardRunning)
            .onSubmit { regenerate(candidate.id) }
            .accessibilityLabel("What should change in \(candidate.selection.name)?")
    }

    private func regenerateButton(_ candidate: MiniWizardCandidate) -> some View {
        Button { regenerate(candidate.id) } label: {
            Text("Regenerate").lineLimit(1).fixedSize()
        }
        .accessibilityLabel("Regenerate \(candidate.selection.name)")
        .disabled(store.isWizardRunning)
    }

    private func currentCandidate(_ id: Int64) -> MiniWizardCandidate? {
        guard store.miniRun?.batchID == run.batchID else { return nil }
        return store.miniRun?.candidates.first { $0.id == id }
    }

    private func regenerate(_ id: Int64) {
        guard !store.isWizardRunning, let candidate = currentCandidate(id) else { return }
        store.regenerateMiniCandidate(selectionID: id, note: candidate.note)
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
                guard generation == store.profileGeneration, store.miniRun?.batchID == run.batchID else { return }
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
                guard generation == store.profileGeneration, store.miniRun?.batchID == run.batchID else { return }
                loadedRows.append(contentsOf: videoRows)
                loadedLabels.merge(videoLabels, uniquingKeysWith: { first, _ in first })
            }
            rows = loadedRows
            labels = loadedLabels
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == store.profileGeneration,
                  store.miniRun?.batchID == run.batchID else { return }
            transcriptError = "Could not load the transcript. Reopen Footage to try again."
        }
    }
}
