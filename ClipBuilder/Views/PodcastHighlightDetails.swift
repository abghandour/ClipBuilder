import SwiftUI

struct PodcastHighlightDetails: View {
    let candidate: HighlightCandidate
    /// The analysis's own range, when the user may have trimmed it.
    var original: HighlightCandidate? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXS) {
            Text(candidate.title).font(.headline)
            HStack(spacing: Theme.spaceS) {
                Text("\(candidate.sourceStart.timecode)–\(candidate.sourceEnd.timecode) · \(candidate.duration, format: .number.precision(.fractionLength(1)))s · Score \(candidate.score, format: .number.precision(.fractionLength(1))) · \(candidate.includesQuestion ? "Q+A" : "Answer only")")
                if let original, candidate.isTrimmed(from: original) {
                    Text("trimmed · suggested \(original.sourceStart.timecode)–\(original.sourceEnd.timecode)")
                        .foregroundStyle(.orange)
                        .help("You changed where this reel starts or ends")
                }
            }
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
