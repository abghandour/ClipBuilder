import SwiftUI

/// Clip inspector section: how many accepted Transcript Tools cleanup cuts
/// fall inside the timeline's clips, and a button that cuts them out of
/// every clip of those videos (one undo step).
struct CleanupCutsInspectorSection: View {
    @Environment(AppStore.self) private var store
    @State private var cuts: [Int64: [ClosedRange<Double>]] = [:]
    @State private var isApplying = false
    @State private var status = ""

    var body: some View {
        let videoIDs = store.builderVideoIDs()
        let total = store.builder.cleanupCutCount(cuts, videoIDsByPath: store.videoIDsByPath)
        InspectorSection("Cleanup Cuts") {
            InspectorRow("Accepted") {
                HStack(spacing: Theme.spaceS) {
                    Text(total == 1 ? "1 cut in this timeline" : "\(total) cuts in this timeline")
                        .lineLimit(1)
                        .fixedSize()
                        .monospacedDigit()
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload(videoIDs) } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Read the cut decisions from Transcript Tools again")
                }
            }
            InspectorRow("") {
                Button("Apply cleanup cuts", systemImage: "scissors") { apply(videoIDs) }
                    .controlSize(.small)
                    .lineLimit(1)
                    .fixedSize()
                    .disabled(total == 0 || isApplying)
                    .help("Cut every accepted filler, stutter, false start, retake and pause out of the clips that play it; later clips move up")
            }
            Text(status.isEmpty
                 ? "Accept cuts in Transcript Tools for the source video, then apply them here."
                 : status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: videoIDs) { await reload(videoIDs) }
    }

    private func reload(_ videoIDs: Set<Int64>) async {
        let generation = store.profileGeneration
        let timelineID = store.builder.timelineID
        let loaded = await store.acceptedCleanupCuts(videoIDs: videoIDs)
        // Drop a read that a profile switch or another open timeline made
        // stale (a changed video set restarts the task with a new id).
        guard !Task.isCancelled, store.profileGeneration == generation,
              store.builder.timelineID == timelineID else { return }
        cuts = loaded
    }

    private func apply(_ videoIDs: Set<Int64>) {
        isApplying = true
        Task {
            if let removed = await store.applyAcceptedCleanupCuts() {
                status = removed > 0
                    ? "Removed \(removed.formatted(.number.precision(.fractionLength(1)))) s. Undo puts it back."
                    : "Nothing to cut: the clips already leave those cuts out."
            } else {
                status = "The timeline changed while the cuts were read. Apply again."
            }
            await reload(store.builderVideoIDs())
            isApplying = false
        }
    }
}
