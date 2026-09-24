import SwiftUI

struct PodcastHighlightScreeningView: View {
    let url: URL
    /// The candidates as edited so far; trims land here as they are made.
    @Binding var candidates: [HighlightCandidate]
    /// What the analysis suggested, for the Reset button.
    let originals: [HighlightCandidate]
    let trim: PodcastHighlightTrim
    @Binding var state: PodcastHighlightScreeningState
    @Binding var isScreening: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            HStack {
                Text(state.isComplete ? "Screening complete" : "\(state.position + 1) of \(candidates.count)")
                    .font(.headline).monospacedDigit()
                Spacer()
                Text("\(state.approved.count) approved").foregroundStyle(.secondary)
            }
            if let index = candidates.firstIndex(where: { $0.id == state.currentID }) {
                let candidate = candidates[index]
                PodcastHighlightTrimView(url: url, candidate: $candidates[index],
                                         original: originals.first { $0.id == candidate.id } ?? candidate,
                                         trim: trim)
                    .id(candidate.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Preview of \(candidate.title)")
                PodcastHighlightDetails(candidate: candidate)
                HStack(spacing: Theme.spaceM) {
                    Button("Thumbs Down", systemImage: "hand.thumbsdown") { rate(.rejected) }
                        .help("Reject and advance (Down Arrow or D)")
                    Button("Thumbs Up", systemImage: "hand.thumbsup") { rate(.approved) }
                        .help("Approve and advance (Up Arrow or U)")
                    if let verdict = state.verdicts[candidate.id] {
                        Text(verdict == .approved ? "Approved" : "Rejected").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } else {
                ContentUnavailableView("Screening complete", systemImage: "checkmark.circle",
                    description: Text("\(state.approved.count) approved · \(state.rejectedCount) rejected · \(state.unratedCount) unrated. Render approved highlights or stop screening to review your selections."))
            }
            HStack {
                Button("Previous") { state.previous() }.disabled(state.position == 0)
                Button("Next") { state.next() }.disabled(state.isComplete)
                Spacer()
                if !state.isComplete {
                    Text("↑ / U approve · ↓ / D reject · Space play · I / O set start / end").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .background {
            PodcastHighlightScreeningKeys(isActive: { isScreening && !state.isComplete }, rate: rate)
                .frame(width: 0, height: 0)
        }
    }

    private func rate(_ verdict: PodcastHighlightScreeningState.Verdict) { state.rate(verdict) }
}
