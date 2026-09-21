import SwiftUI

struct PodcastHighlightDetails: View {
    let candidate: HighlightCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXS) {
            Text(candidate.title).font(.headline)
            Text("\(candidate.sourceStart.timecode)–\(candidate.sourceEnd.timecode) · \(candidate.duration, format: .number.precision(.fractionLength(1)))s · Score \(candidate.score, format: .number.precision(.fractionLength(1))) · \(candidate.includesQuestion ? "Q+A" : "Answer only")")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Text(candidate.framing.name).font(.caption).help(candidate.framing.summary)
            Text(candidate.reason).font(.callout)
            if let standalone = candidate.standalone {
                Text(standalone ? "Standalone" : "Needs context")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
