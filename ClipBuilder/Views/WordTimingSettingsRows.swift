import SwiftUI

/// Settings → General → Transcription: the word timing a new transcript
/// gets when nothing asks, and the model precise timing needs.
struct WordTimingSettingsRows: View {
    @Environment(AppStore.self) private var store
    @State private var installed = WordAlignerModel.isInstalled
    @State private var confirmingRemoval = false
    @State private var failure = ""

    private var installing: Bool { store.jobs.running.contains { $0.kind == .wordTimingModel } }

    var body: some View {
        @Bindable var store = store
        Picker("Default word timing", selection: $store.settings.wordTimingChoice) {
            ForEach(WordTiming.allCases) { Text($0.label).tag($0) }
        }
        // On the picker, which is always in the form: a modifier on an
        // empty view never runs. Re-read the disk when a job ends.
        .task(id: store.jobs.completionRevision(.wordTimingModel)) { installed = WordAlignerModel.isInstalled }
        .onChange(of: installing) { installed = WordAlignerModel.isInstalled }
        .help("Apple's word times sit on a coarse grid and absorb pauses. Precise re-times each Portuguese word against the audio after transcription; other languages keep Apple's times. Transcribe and Re-transcribe ask which to use for a Portuguese video; analysis and the wizard use this default.")
        LabeledContent("Portuguese timing model") {
            HStack(spacing: 8) {
                if installing {
                    ProgressView().controlSize(.small)
                    Text("Installing…").lineLimit(1).fixedSize()
                } else if installed {
                    Label("Installed", systemImage: "checkmark.circle").lineLimit(1).fixedSize()
                    Button("Remove…") { confirmingRemoval = true }.lineLimit(1).fixedSize()
                } else {
                    Text("Not installed").foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    Button("Download (260 MB)", systemImage: "arrow.down.circle") { store.installWordTimingModel() }
                        .lineLimit(1).fixedSize()
                }
            }
        }
        .confirmationDialog("Remove the word timing model?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) {
                do {
                    try WordAlignerModel.remove()
                    // Otherwise the next Portuguese project fetches it again.
                    WordAlignerModel.autoInstallDeclined = true
                    failure = ""
                } catch { failure = "Could not remove the model: \(error.localizedDescription)" }
                installed = WordAlignerModel.isInstalled
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New Portuguese transcripts use Apple's word times until it is downloaded again, and it is no longer downloaded automatically. Existing transcripts keep the times they have.")
        }
        Text(installed
             ? "Precise timing applies to Portuguese transcripts made from now on. Re-transcribe a video to re-time it; that makes a new transcript set without the old one's edits."
             : "Downloaded automatically when a project speaks Portuguese. Until it is installed, transcripts keep Apple's word times and there is no model to choose when transcribing.")
            .font(.caption).foregroundStyle(.secondary)
        if !failure.isEmpty { Text(failure).font(.caption).foregroundStyle(.red) }
    }
}
