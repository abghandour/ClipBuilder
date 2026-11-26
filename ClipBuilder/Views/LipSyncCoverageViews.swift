import SwiftUI

/// The lip sync takes on disk, read once off the main thread and again
/// whenever a take is made. Lists and the preview player read coverage from it.
@Observable final class LipSyncTakeIndex {
    static let shared = LipSyncTakeIndex()
    private(set) var takes: [LipSyncTakes.Take] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var checked = Date.distantPast

    /// Called whenever a list or the preview appears: takes are checked
    /// against their recordings again, at most every few seconds.
    func ensureLoaded() {
        if Date().timeIntervalSince(checked) > 5 {
            checked = Date()
            Task { await reload() }
        }
        guard !started else { return }
        started = true
        Task {
            for await _ in NotificationCenter.default.notifications(named: LipSyncTakes.changed) {
                await reload()
            }
        }
    }

    private func reload() async {
        let found = await Task.detached(priority: .utility) {
            // A recording replaced at the same path no longer owns its takes.
            var prints: [String: String?] = [:]
            return LipSyncTakes.all().filter { take in
                guard let made = take.fingerprint else { return false }
                if prints[take.sourcePath] == nil {
                    prints[take.sourcePath] = .some(try? SourceIdentityCache.shared.fingerprint(of: URL(fileURLWithPath: take.sourcePath)))
                }
                guard let now = prints[take.sourcePath] ?? nil else { return true }
                return now == made
            }
        }.value
        if found != takes { takes = found }
    }

    func coverage(path: String?, start: Double, end: Double) -> LipSyncTakes.Coverage {
        guard let path, !takes.isEmpty else { return .init(synced: 0, total: max(0, end - start), take: nil) }
        return LipSyncTakes.coverage(path: path, start: start, end: end, takes: takes)
    }
}

/// Under a clip's row: whether its picture is already lip-synced, and how much of it.
struct LipSyncCoverageLine: View {
    var path: String?
    var start: Double
    var end: Double
    @State private var index = LipSyncTakeIndex.shared

    var body: some View {
        let coverage = index.coverage(path: path, start: start, end: end)
        Group {
            if let label = coverage.label {
                HStack(spacing: Theme.spaceXS) {
                    Label(label, systemImage: "mouth")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                    if !coverage.isComplete {
                        ProgressView(value: coverage.fraction)
                            .progressViewStyle(.linear).controlSize(.mini)
                            .frame(width: 48)
                            .accessibilityHidden(true)
                    }
                }
                .help(coverage.isComplete
                      ? "This clip's picture is already lip-synced. Generate reuses it while the clip and its dubbed lines stay the same."
                      : "Part of this clip is lip-synced. Generate makes the rest when Lip sync is on.")
            }
        }
        .onAppear { index.ensureLoaded() }
    }
}

/// Above a clip list: how much of the reel already has lip-synced picture.
struct LipSyncSummaryLine: View {
    var clips: [(path: String?, start: Double, end: Double)]
    @State private var index = LipSyncTakeIndex.shared

    var body: some View {
        let coverage = clips.map { index.coverage(path: $0.path, start: $0.start, end: $0.end) }
        let total = coverage.reduce(0) { $0 + $1.total }
        let synced = coverage.reduce(0) { $0 + min($1.synced, $1.total) }
        Group {
            if let summary = LipSyncTakes.summary(coverage) {
                HStack(spacing: Theme.spaceS) {
                    ProgressView(value: total > 0 ? min(1, synced / total) : 0)
                        .progressViewStyle(.linear).controlSize(.small)
                        .frame(width: 64)
                        .accessibilityHidden(true)
                    Text(summary).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .help("Lip-synced picture is kept per clip of the recording, before the camera and overlays, and reused by every later Generate.")
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear { index.ensureLoaded() }
    }
}
