import SwiftUI

struct PodcastHighlightReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: PodcastHighlightReviewRequest
    @State private var rows: [Selection]
    /// The candidate open in the Play sheet (its id; edits go to `rows`).
    @State private var playingID: UUID?
    @State private var renderFailure: String?
    @State private var screening: PodcastHighlightScreeningState
    @State private var isScreening = false
    @State private var hasScreened = false
    /// The recording's words, for word-snapped trimming.
    private let trim: PodcastHighlightTrim

    private struct Selection: Identifiable {
        var candidate: HighlightCandidate
        var selected = true
        var id: UUID { candidate.id }
    }

    init(request: PodcastHighlightReviewRequest) {
        self.request = request
        _screening = State(initialValue: PodcastHighlightScreeningState(candidateIDs: request.candidates.map(\.id)))
        _rows = State(initialValue: request.candidates.map { Selection(candidate: $0) })
        trim = PodcastHighlightTrim(segments: request.segments, turns: request.turns, roster: request.roster,
                                    duration: request.video.duration)
    }

    /// The candidates as trimmed so far, for the screening view.
    private var candidatesBinding: Binding<[HighlightCandidate]> {
        Binding(get: { rows.map(\.candidate) },
                set: { edited in
                    for candidate in edited {
                        if let index = rows.firstIndex(where: { $0.id == candidate.id }) { rows[index].candidate = candidate }
                    }
                })
    }

    private func original(for id: UUID) -> HighlightCandidate? {
        request.candidates.first { $0.id == id }
    }

    /// The request with the trimmed ranges, so rendering cuts what was reviewed.
    private var editedRequest: PodcastHighlightReviewRequest {
        var edited = request
        edited.candidates = rows.map(\.candidate)
        return edited
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
                PodcastHighlightScreeningView(url: request.video.url, candidates: candidatesBinding,
                    originals: request.candidates, trim: trim, state: $screening, isScreening: $isScreening)
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
                                PodcastHighlightDetails(candidate: row.candidate, original: original(for: row.id))
                                Spacer()
                                if let original = original(for: row.id), row.candidate.isTrimmed(from: original) {
                                    Button("Reset") {
                                        row.candidate.sourceStart = original.sourceStart
                                        row.candidate.sourceEnd = original.sourceEnd
                                    }
                                    .controlSize(.small)
                                    .help("Return to the suggested \(original.sourceStart.timecode)–\(original.sourceEnd.timecode)")
                                }
                                Button("Play", systemImage: "play.fill") { playingID = row.id }
                                    .help("Watch it and adjust where it starts and ends")
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(Theme.spaceM)
        .frame(width: isScreening ? PodcastHighlightTrimView.sheetWidth : 820,
               height: isScreening ? PodcastHighlightTrimView.sheetHeight : 620)
        .sheet(item: playingSelection) { row in
            PodcastHighlightTrimSheet(url: request.video.url, candidate: playingBinding(for: row.id),
                                      original: original(for: row.id) ?? row.candidate, trim: trim)
        }
    }

    /// The row open in the Play sheet, or nil once it is dismissed.
    private var playingSelection: Binding<Selection?> {
        Binding(get: { playingID.flatMap { id in rows.first { $0.id == id } } },
                set: { playingID = $0?.id })
    }

    private func playingBinding(for id: UUID) -> Binding<HighlightCandidate> {
        Binding(get: { (rows.first { $0.id == id } ?? rows[0]).candidate },
                set: { candidate in
                    if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].candidate = candidate }
                })
    }

    private func startScreening() {
        playingID = nil
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
        playingID = nil
        isScreening = false
        store.pendingPodcastHighlights = nil
        dismiss()
    }

    private func render(selected: Set<UUID>) {
        if store.renderPodcastHighlights(editedRequest, selected: selected) {
            isScreening = false
            dismiss()
        } else {
            renderFailure = store.wizardFailureMessage
        }
    }
}
