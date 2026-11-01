import SwiftUI

/// The few reels and sibling pairs where the trained models, the AI critic
/// and human judgments disagree most. A pair pick informs the outcome model's
/// evaluation, so Re-evaluate counts only pair answers; a reel verdict feeds
/// the wizard's lessons. See docs/Teaching-Queue-Plan.md.
@MainActor
struct TeachingQueueSection: View {
    @Environment(AppStore.self) private var store
    @State private var reviewing: GeneratedVideoRecord?

    private var evaluating: Bool { store.jobs.running.contains { $0.kind == .evaluateReelModel } }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Where your judgment teaches the most: the reels the models and the critic disagree on.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if store.isRefreshingTeachingQueue { ProgressView().controlSize(.small) }
                    Button("Refresh") { Task { await store.refreshTeachingQueue() } }
                        .buttonStyle(.bordered).controlSize(.small)
                        .lineLimit(1).fixedSize()
                        .disabled(store.isRefreshingTeachingQueue)
                        .help("Rebuild the queue from the current models, critiques, reviews and picks")
                    Button(reevaluateTitle) { store.reevaluateTaughtModels() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .lineLimit(1).fixedSize()
                        .disabled(store.teachingPending.isEmpty || evaluating)
                        .help(store.teachingPending.isEmpty
                              ? "Pick the better reel of a pair first; pair picks mark the outcome model for re-evaluation."
                              : "Evaluate " + pendingNames + " again with your new answers")
                    Spacer(minLength: 0)
                }
                if store.teachingQueue.isEmpty {
                    Text(store.isRefreshingTeachingQueue ? "Looking for disagreements…"
                         : "Nothing to teach right now. Disagreements appear once at least two sources (an evaluated model, the critic) have scored your reels.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(store.teachingQueue) { item in
                        row(item)
                        if item.id != store.teachingQueue.last?.id { Divider() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        } label: {
            Text("Teaching queue").font(.headline)
        }
        .task(id: store.profileGeneration) { await store.refreshTeachingQueue() }
        .onChange(of: store.jobs.completionRevision(.evaluateReelModel)) {
            Task { await store.refreshTeachingQueue() }
        }
        .onChange(of: store.pendingComparison == nil) { _, closed in
            if closed { Task { await store.refreshTeachingQueue() } }
        }
        .sheet(item: $reviewing, onDismiss: { Task { await store.refreshTeachingQueue() } }) { video in
            ReviewSheet(video: video)
        }
    }

    private var pendingNames: String {
        ReelModelItem.allCases.filter { store.teachingPending.contains($0) }
            .map { ReelModelInfo.entry($0).title }.joined(separator: ", ")
    }

    private var reevaluateTitle: String {
        store.teachingPending.isEmpty ? "Re-evaluate" : "Re-evaluate (\(store.teachingPending.count))"
    }

    private func title(_ item: TeachingQueue.Item) -> String {
        func name(_ id: Int64) -> String { store.teachingQueueVideos[id]?.filename ?? "Reel \(id)" }
        switch item.kind {
        case .reel(let id): return name(id)
        case .pair(let a, let b): return "\(name(a)) vs \(name(b))"
        }
    }

    private func row(_ item: TeachingQueue.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title(item)).lineLimit(1).truncationMode(.middle)
                Text(item.summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Disagree: " + item.disagreeing.map(\.label).joined(separator: " vs ")
                     + " · informs: " + informsText(item))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text("\(Int((item.disagreement * 100).rounded()))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
                .help("How far apart the sources rank this")
            Button("Judge") { judge(item) }
                .buttonStyle(.bordered).controlSize(.small)
                .lineLimit(1).fixedSize()
                .help(isPair(item) ? "Pick the better of the two reels" : "Review this reel")
        }
    }

    /// A reel verdict feeds no on-device model, only the wizard's lessons.
    private func informsText(_ item: TeachingQueue.Item) -> String {
        item.informs.isEmpty
            ? TeachingQueue.reelVerdictDestination
            : item.informs.map { ReelModelInfo.entry($0).title }.joined(separator: ", ")
    }

    private func isPair(_ item: TeachingQueue.Item) -> Bool {
        if case .pair = item.kind { return true }
        return false
    }

    private func judge(_ item: TeachingQueue.Item) {
        switch item.kind {
        case .reel(let id): reviewing = store.teachingQueueVideos[id]
        case .pair(let a, let b): store.judgeTeachingPair(a, b)
        }
    }
}
