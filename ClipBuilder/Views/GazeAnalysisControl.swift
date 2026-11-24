import SwiftUI

/// The Sources inspector's recording action. Its receipt comes from the same
/// stored rows on every Mac, including a successful pass with no glances.
struct GazeAnalysisControl: View {
    let video: VideoRecord
    @Environment(AppStore.self) private var store
    @State private var awayShare: Double?
    @State private var loadError: String?

    private var measuring: Bool {
        store.jobs.running.contains {
            $0.kind == .gaze && $0.subjectID == String(video.id) && $0.profileGeneration == store.profileGeneration
        }
    }

    private struct RefreshKey: Equatable {
        var videoID: Int64
        var generation: Int
        var completed: Int
        var syncing: Bool
        var attaching: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Gaze").font(.caption.weight(.medium))
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 0)
                if measuring { ProgressView().controlSize(.small) }
                Button("Measure gaze") { store.measureGaze(video: video) }
                    .controlSize(.small)
                    .lineLimit(1).fixedSize()
                    .disabled(measuring || awayShare != nil || !video.isLocal)
                    .help("Measure departures from the person's usual gaze once for this recording. Progress and Stop appear in the status bar.")
            }
            Text(status).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
        .task(id: RefreshKey(videoID: video.id, generation: store.profileGeneration,
                            completed: store.jobs.completionRevision(.gaze),
                            syncing: store.teamSync.syncing, attaching: store.teamSync.attaching)) {
            await refresh()
        }
    }

    private var status: String {
        if measuring { return "Measuring…" }
        if let awayShare { return "Measured · \(Int((awayShare * 100).rounded()))% of time away" }
        return loadError ?? "Not measured"
    }

    private func refresh() async {
        awayShare = nil
        loadError = nil
        guard let database = store.database else { return }
        do {
            let share = try await database.gazeAwayShare(videoID: video.id)
            guard !Task.isCancelled else { return }
            awayShare = share
        } catch {
            guard !Task.isCancelled else { return }
            loadError = "Gaze status unavailable"
            ErrorLog.record("Gaze status", error.localizedDescription)
        }
    }
}
