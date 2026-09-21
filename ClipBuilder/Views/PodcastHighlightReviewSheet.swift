import SwiftUI

struct PodcastHighlightReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: PodcastHighlightReviewRequest
    @State private var rows: [Selection]
    @State private var playing: HighlightCandidate?
    @State private var renderFailure: String?
    @State private var screening: PodcastHighlightScreeningState
    @State private var isScreening = false
    @State private var hasScreened = false

    private struct Selection: Identifiable {
        var candidate: HighlightCandidate
        var selected = true
        var id: UUID { candidate.id }
    }

    init(request: PodcastHighlightReviewRequest) {
        self.request = request
        _screening = State(initialValue: PodcastHighlightScreeningState(candidateIDs: request.candidates.map(\.id)))
        _rows = State(initialValue: request.candidates.map { Selection(candidate: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            HStack {
                VStack(alignment: .leading, spacing: Theme.spaceXS) {
                    Text("Review Podcast Highlights").font(.headline)
                    Text(request.video.filename).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                if isScreening {
                    Button("Stop Screening", action: stopScreening)
                    if screening.isComplete {
                        Button("Render Approved (\(screening.approved.count))") { render(selected: screening.approved) }
                            .buttonStyle(.borderedProminent)
                            .disabled(screening.approved.isEmpty)
                    }
                } else {
                    Button("Screen One by One", action: startScreening).disabled(rows.isEmpty)
                    Button("Render \(hasScreened ? "Approved" : "Selected") (\(rows.filter(\.selected).count))") {
                        render(selected: Set(rows.filter(\.selected).map(\.id)))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!rows.contains(where: \.selected))
                }
            }
            HStack {
                Text("Each selection becomes a separate reel. Plain footage, speaker framing and relevant B-roll.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !isScreening, !rows.isEmpty {
                    // One button that flips between the two bulk actions.
                    let allSelected = rows.allSatisfy(\.selected)
                    Button(allSelected ? "Deselect All" : "Select All") {
                        for index in rows.indices { rows[index].selected = !allSelected }
                    }
                    .controlSize(.small)
                    .accessibilityLabel(allSelected ? "Deselect all highlights" : "Select all highlights")
                }
            }
            if let renderFailure {
                Text(renderFailure).font(.callout).foregroundStyle(.red)
            }
            Divider()
            if isScreening {
                PodcastHighlightScreeningView(url: request.video.url, candidates: request.candidates,
                    state: $screening, isScreening: $isScreening)
            } else if rows.isEmpty {
                ContentUnavailableView("No highlights found", systemImage: "waveform",
                    description: Text("No sentence-safe candidates met the score threshold and maximum length. Try a longer maximum or another recording."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.spaceM) {
                        ForEach($rows) { $row in
                            HStack(alignment: .top, spacing: Theme.spaceM) {
                                Toggle(row.candidate.title, isOn: $row.selected).labelsHidden()
                                    .accessibilityLabel("Include \(row.candidate.title)")
                                PodcastHighlightDetails(candidate: row.candidate)
                                Spacer()
                                Button("Play", systemImage: "play.fill") { playing = row.candidate }
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(Theme.spaceM)
        .frame(width: 820, height: 620)
        .sheet(item: $playing) { candidate in
            PlayerSheet(url: request.video.url, transcriptVideoID: request.video.id, title: candidate.title,
                        startTime: candidate.sourceStart, endTime: candidate.sourceEnd)
        }
    }

    private func startScreening() {
        playing = nil
        if screening.isComplete { screening.restart() }
        isScreening = true
    }

    private func stopScreening() {
        let selected = screening.selectionOnStop(previous: Set(rows.filter(\.selected).map(\.id)))
        for index in rows.indices { rows[index].selected = selected.contains(rows[index].id) }
        hasScreened = true
        isScreening = false
    }

    private func cancel() {
        playing = nil
        isScreening = false
        store.pendingPodcastHighlights = nil
        dismiss()
    }

    private func render(selected: Set<UUID>) {
        if store.renderPodcastHighlights(request, selected: selected) {
            isScreening = false
            dismiss()
        } else {
            renderFailure = store.wizardFailureMessage
        }
    }
}
