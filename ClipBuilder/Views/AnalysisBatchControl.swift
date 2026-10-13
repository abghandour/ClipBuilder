import SwiftUI

/// Shared popover for the status slot and the preview's Change control.
struct AnalysisBatchControl: View {
    /// Passed in, not read from the environment: a Table cell can be updated
    /// after its row is recycled, when the environment no longer carries the
    /// store, and an environment lookup then asserts.
    let store: AppStore
    let video: VideoRecord
    var compact = false
    let onCompare: ([AnalysisRun]) -> Void
    @State private var showingBatches = false
    @State private var deleting: AnalysisRun?

    private var runs: [AnalysisRun] { store.analysisRuns.filter { $0.videoID == video.id } }
    private var active: ActiveLayers.Resolution { store.activeLayer(videoID: video.id) }

    var body: some View {
        Button {
            showingBatches = true
        } label: {
            if compact {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 2) {
                        Image(systemName: "square.stack")
                        Text("\(active.run?.sceneCount ?? 0)")
                        if runs.count > 1 { Text("+\(runs.count - 1)").foregroundStyle(.secondary) }
                    }
                    .fixedSize()
                    HStack(spacing: 2) {
                        Image(systemName: "square.stack")
                        Text(runs.count > 1 ? "+\(runs.count - 1)" : "\(active.run?.sceneCount ?? 0)")
                    }
                    .fixedSize()
                }
                .font(.caption2.monospacedDigit()).frame(width: 58, alignment: .leading)
            } else {
                Text("Change…")
            }
        }
        .lineLimit(1).fixedSize()
        .buttonStyle(.borderless)
        .accessibilityLabel("Change analysis batch")
        .help("\(active.run?.sceneCount ?? 0) active scenes · \(runs.count) batches"
              + (active.missingPin ? " · pinned batch not on this Mac yet" : ""))
        .popover(isPresented: $showingBatches) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Analysis batches").font(.headline)
                if active.missingPin {
                    Text("pinned batch not on this Mac yet").foregroundStyle(.orange)
                }
                if let checkpoint = store.analysisCheckpoints[video.id] {
                    Text("Unfinished work: \(checkpoint.percent)% · \(checkpoint.stage)")
                        .font(.caption).foregroundStyle(.orange)
                }
                if runs.isEmpty { Text("No batches on this Mac.").foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(runs) { run in
                            batchRow(run)
                        }
                    }
                }
                .frame(maxHeight: 330)
                HStack {
                    Button("Use automatic") { store.pinAnalysisRun(videoID: video.id, runKey: nil) }
                        .disabled(video.activeRunKey == nil)
                    Button("Compare…") {
                        showingBatches = false
                        onCompare(runs)
                    }
                    .disabled(runs.count < 2)
                }
                .lineLimit(1).fixedSize()
            }
            .padding().frame(width: 390)
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting) { run in
                Button("Delete Batch", role: .destructive) { store.deleteAnalysisRun(run); deleting = nil }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { run in
                Text(store.batchDeletionMessage([run]))
            }
    }

    private func batchRow(_ run: AnalysisRun) -> some View {
        let pipeline = AISettingsJSON.decode(AnalysisRunSettings.self, run.settingsJSON)?.pipeline
        let tags = Set(store.historyScenes.filter { $0.runID == run.id }.flatMap(\.tags)).count
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.name).fontWeight(.medium).lineLimit(1)
                Spacer()
                if active.run?.id == run.id {
                    Text(active.isPinned ? "active · pinned" : "active · newest")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
            Text("\(run.createdAt ?? "Unknown date") · Pipeline \(pipeline.map(String.init) ?? "unknown")")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(run.sceneCount) scenes · \(tags) tags · \(ActiveLayers.isCompleted(run, passes: store.analysisPasses) ? "Completed" : "Not completed")")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Pin") { store.pinAnalysisRun(videoID: video.id, runKey: run.runKey) }
                    .disabled(run.runKey == nil || (active.isPinned && active.run?.id == run.id))
                Button("Delete…", role: .destructive) {
                    showingBatches = false
                    store.prepareBatchDeletion { deleting = run }
                }
            }
            .controlSize(.small).lineLimit(1).fixedSize()
            Divider()
        }
    }
}
