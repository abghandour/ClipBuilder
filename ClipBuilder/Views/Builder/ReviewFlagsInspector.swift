import SwiftUI

/// The "Review" section above the selection's settings: the moments of the
/// generated video this timeline came from that the pipeline was unsure
/// about, each with a Jump button that selects its clip and seeks there.
struct ReviewFlagsInspector: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let flags = store.builder.reviewFlags
        InspectorSection("Review") {
            Text("\(flags.count) moment\(flags.count == 1 ? "" : "s") to check")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                ForEach(flags) { flag in
                    row(flag)
                }
            }
        }
        .padding()
    }

    private func row(_ flag: ReviewFlag) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.spaceS) {
            Image(systemName: Self.icon(for: flag.kind))
                .foregroundStyle(flag.severity == .warning ? Color.orange : Color.secondary)
                .help(Self.title(for: flag.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(flag.message)
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ReviewFlagBuilder.timeLabel(flag.time))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Jump") { store.builder.jump(to: flag) }
                .controlSize(.small)
                .lineLimit(1)
                .fixedSize()
                .help("Select this clip and move the playhead to \(ReviewFlagBuilder.timeLabel(flag.time))")
        }
    }

    static func icon(for kind: ReviewFlag.Kind) -> String {
        switch kind {
        case .unnamedSpeaker: "person.fill.questionmark"
        case .lowConfidenceSpeaker: "person.wave.2"
        case .framingFallback: "crop"
        case .noTrackingPath: "viewfinder"
        case .qualityWarning: "exclamationmark.triangle"
        }
    }

    static func title(for kind: ReviewFlag.Kind) -> String {
        switch kind {
        case .unnamedSpeaker: "Unnamed speaker"
        case .lowConfidenceSpeaker: "Uncertain speaker"
        case .framingFallback: "Framing fell back"
        case .noTrackingPath: "No tracking path"
        case .qualityWarning: "Quality gate"
        }
    }
}
