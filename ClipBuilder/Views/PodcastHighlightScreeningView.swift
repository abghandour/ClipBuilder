import SwiftUI

struct PodcastHighlightScreeningView: View {
    let url: URL
    let candidates: [HighlightCandidate]
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
            if let candidate = candidates.first(where: { $0.id == state.currentID }) {
                PodcastHighlightRangePlayer(url: url, candidate: candidate)
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
                    Text("↑ / U approve · ↓ / D reject").font(.caption).foregroundStyle(.secondary)
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
