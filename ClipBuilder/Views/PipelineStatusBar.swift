import SwiftUI

/// Window-wide bottom strip while a Wizard Pipeline run works through its
/// steps: current stage, progress, Stop — click anywhere on it for the full
/// log. Stays after the run finishes (as "done"/"stopped") until dismissed.
struct PipelineStatusBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.rays")
                .foregroundStyle(Theme.createTint)
            Text(store.pipelineStage.isEmpty
                 ? "Wizard Pipeline"
                 : "Wizard Pipeline — \(store.pipelineStage)")
                .font(.caption)
                .lineLimit(1)
            ProgressView(value: store.pipelineProgress)
                .frame(maxWidth: 220)
            Spacer()
            if store.isPipelineRunning {
                Button("Stop", systemImage: "stop.circle") {
                    store.cancelPipeline()
                }
                .controlSize(.small)
                .help("Stop the Wizard Pipeline run — finished steps are kept and Resume picks up from here")
            } else {
                if store.canResumePipeline {
                    Button("Resume", systemImage: "play.circle") {
                        store.resumePipeline()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .help("Continue the stopped run — finished steps are skipped")
                }
                Button("Dismiss") {
                    store.dismissPipelineBar()
                }
                .controlSize(.small)
                .help("Hide this bar (the run's log and resume point go with it)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { store.showPipelineLog = true }
        .help("Click for the full Wizard Pipeline log")
    }
}

/// The run's full log, live while it works — auto-follows the newest line.
struct PipelineLogSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Wizard Pipeline")
                    .font(.headline)
                if store.isPipelineRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(store.pipelineStage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Log", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.pipelineLog.joined(separator: "\n"),
                                                   forType: .string)
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .help("Copy the whole log")
                Button("Clear Log", systemImage: "trash") {
                    store.pipelineLog = []
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .help("Clear the log")
                if store.isPipelineRunning {
                    Button("Stop", systemImage: "stop.circle") {
                        store.cancelPipeline()
                    }
                    .controlSize(.small)
                }
            }
            ProgressView(value: store.pipelineProgress)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(store.pipelineLog.enumerated()), id: \.offset) { entry in
                            Text(entry.element)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(entry.offset)
                        }
                    }
                    .padding(8)
                }
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: store.pipelineLog.count) {
                    proxy.scrollTo(store.pipelineLog.count - 1, anchor: .bottom)
                }
                .onAppear {
                    proxy.scrollTo(store.pipelineLog.count - 1, anchor: .bottom)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 340, idealHeight: 460)
        .modalCloseButton { dismiss() }
    }
}
