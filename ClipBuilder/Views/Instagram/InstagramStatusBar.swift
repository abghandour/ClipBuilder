import SwiftUI

/// Window-wide bottom strip while an Instagram refresh or a report-history
/// import runs — current stage, progress, the newest log line, Stop — the
/// same pattern as the Wizard Pipeline strip. Click anywhere on it for the
/// full log. Stays after the run finishes ("done"/"stopped"/"failed") until
/// dismissed.
struct InstagramStatusBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let status = store.igStatus
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle")
                .foregroundStyle(Theme.instagramTint)
            Text(status.map { $0.stage.isEmpty ? $0.title : "\($0.title) — \($0.stage)" } ?? "Instagram")
                .font(.caption)
                .lineLimit(1)
                .layoutPriority(1)
            ProgressView(value: status?.fraction ?? 0)
                .frame(maxWidth: 220)
            if status?.running == true, let last = store.igLog.last {
                Text(last)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if status?.running == true {
                Button("Stop", systemImage: "stop.circle") {
                    store.cancelInstagramWork()
                }
                .controlSize(.small)
                .help("Stop — finished steps are kept and the next run resumes from its checkpoints")
            } else {
                Button("Dismiss") {
                    store.dismissIGStatusBar()
                }
                .controlSize(.small)
                .help("Hide this bar (the log stays on the Instagram screen until the next run)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { store.showIGLog = true }
        .help("Click for the full Instagram sync log")
    }
}

/// The run's full log, live while it works — auto-follows the newest line.
struct InstagramLogSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(store.igStatus?.title ?? "Instagram")
                    .font(.headline)
                if store.igStatus?.running == true {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(store.igStatus?.stage ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                LogActions(lines: store.igLog) { store.igLog = [] }
                if store.igStatus?.running == true {
                    Button("Stop", systemImage: "stop.circle") {
                        store.cancelInstagramWork()
                    }
                    .controlSize(.small)
                }
            }
            ProgressView(value: store.igStatus?.fraction ?? 0)

            ActivityLogView(lines: \.igLog)
                .padding(8)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 340, idealHeight: 460)
        .modalCloseButton { dismiss() }
    }
}
