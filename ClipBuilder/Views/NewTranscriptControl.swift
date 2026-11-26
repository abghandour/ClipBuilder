import SwiftUI

/// "New Transcript" in the transcript sheet's title bar: one click opens a
/// small chooser with every model that can run, a second starts it. The
/// sheet stays open; while the transcription runs this shows it, with Stop.
struct NewTranscriptControl: View {
    @Environment(AppStore.self) private var store
    let video: VideoRecord
    /// Edited lines of the version in use, named in the chooser.
    let editedCount: Int
    /// Unsaved changes in the sheet: a new version would switch away from them.
    let blocked: Bool
    @Binding var isPresented: Bool

    /// The model picked last time, offered first the next.
    @AppStorage("TranscriptLastEngine") private var lastEngine = ""
    @State private var engines: [TranscriptionEngine] = [.apple(.recognizer)]
    @State private var engine: TranscriptionEngine = .apple(.recognizer)
    @State private var hasKey = true

    private var transcribing: Bool { store.transcribingVideoIDs.contains(video.id) }

    var body: some View {
        if transcribing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                Button("Stop", systemImage: "stop.circle") { store.cancelTranscription(videoID: video.id) }
                    .labelStyle(.iconOnly)
                    .help("Stop transcribing this video")
            }
            .accessibilityElement(children: .contain)
        } else {
            Button("New Transcript", systemImage: "waveform.badge.plus") { isPresented = true }
                .lineLimit(1).fixedSize()
                .disabled(blocked || !video.isPresent)
                .help(blocked ? "Apply or discard your changes first"
                      : !video.isPresent ? VideoRecord.notPresentReason
                      : "Transcribe this video again, with the model you choose. The version on show stays in the Version menu.")
                .popover(isPresented: $isPresented, arrowEdge: .bottom) { chooser }
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Transcript").font(.headline)
            Picker("Model", selection: $engine) {
                ForEach(engines) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup).labelsHidden()
            Text(engine.detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !hasKey {
                Label("To transcribe with ElevenLabs Scribe, add your key in Settings › AI.", systemImage: "key")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Makes a new version and puts it in use. The version on show stays in the Version menu"
                 + (editedCount > 0 ? ", with its \(editedCount) edited lines." : "."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Transcribe") {
                    lastEngine = engine.id
                    isPresented = false
                    store.transcribe(video: video, force: true, engine: engine)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
        .task {
            // Reads the keychain and the model folder once, as the chooser opens.
            let available = store.availableTranscriptionEngines(for: [video], force: true)
            engines = available
            hasKey = available.contains(where: \.isCloud)
            engine = TranscriptionEngineRules.initial(available: available, last: lastEngine.isEmpty ? nil : lastEngine,
                                                      preferred: store.settings.transcriptionEngine)
        }
    }
}
