import SwiftUI

/// Soundbite finder: the model mines a video's transcript for its most
/// quotable self-contained moments — each shown with timestamps, the verbatim
/// quote, a suggested overlay line, and why it lands. Checked soundbites can
/// be saved as timestamped video notes, where they guide the next analysis
/// and are visible in the plan sheet's notes panel.
struct SoundbiteSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let video: VideoRecord

    @State private var isRunning = false
    @State private var statusLine = ""
    @State private var errorMessage: String?
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))
    @State private var soundbites: [SoundbiteFinder.Soundbite]?
    /// The model that mined them — stamped on the saved notes.
    @State private var provenance: AIProvenance?
    @State private var included: [Double: Bool] = [:]
    @State private var isSaving = false

    var body: some View {
        Group {
            if let soundbites {
                results(soundbites)
            } else {
                setup
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 280, idealHeight: 400)
        .modalCloseButton { dismiss() }
        .task {
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
            if modelTag.isEmpty {
                modelTag = ModelPicker.bestAvailableTag(for: "soundbites",
                                                        available: availableProviders)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Soundbites")
                .font(.title3.bold())
            Text("Mines the transcript of \(video.filename) for the most quotable self-contained moments — the lines worth building a reel around — each with timestamps and a suggested overlay caption.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ModelPicker(title: "Model", task: "soundbites", selection: $modelTag,
                            availableProviders: availableProviders)
                    .fixedSize()
                Spacer()
            }

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusLine.isEmpty ? "Reading the transcript…" : statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(isRunning ? "Finding…" : "Find Soundbites") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning)
            }
        }
        .padding(20)
    }

    private func results(_ soundbites: [SoundbiteFinder.Soundbite]) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text("\(soundbites.count) soundbite\(soundbites.count == 1 ? "" : "s")")
                        .font(.headline)
                    if let provenance {
                        ProvenanceBadge(provenance: provenance, style: .full, role: "Found by")
                    }
                }
                Text("Checked soundbites save as timestamped video notes — they guide the next analysis and show in the plan sheet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(soundbites) { soundbite in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { included[soundbite.id] ?? true },
                                set: { included[soundbite.id] = $0 }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("\(soundbite.start.timecode)–\(soundbite.end.timecode)")
                                        .font(.caption.monospacedDigit().bold())
                                    if !soundbite.reason.isEmpty {
                                        Text(soundbite.reason)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Text("“\(soundbite.quote)”")
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !soundbite.overlayLine.isEmpty {
                                    Text("Overlay: \(soundbite.overlayLine)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal)
            }

            HStack {
                Spacer()
                let count = soundbites.count { included[$0.id] ?? true }
                Button(isSaving ? "Saving…" : "Save as Video Notes") {
                    save(soundbites.filter { included[$0.id] ?? true })
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0 || isSaving)
            }
            .padding()
        }
    }

    private func run() {
        let (provider, model) = ModelPicker.parse(modelTag)
        isRunning = true
        errorMessage = nil
        Task {
            do {
                let found = try await store.findSoundbites(
                    in: video, provider: provider, model: model) { message in
                    if let line = AIProgressLine.from(message) { Task { @MainActor in statusLine = line } }
                }
                soundbites = found.value
                provenance = found.provenance
            } catch {
                errorMessage = error.userMessage
            }
            isRunning = false
        }
    }

    private func save(_ picked: [SoundbiteFinder.Soundbite]) {
        isSaving = true
        Task {
            for soundbite in picked {
                var note = "Soundbite: “\(soundbite.quote)”"
                if !soundbite.overlayLine.isEmpty {
                    note += " — overlay: “\(soundbite.overlayLine)”"
                }
                _ = await store.addVideoNote(videoID: video.id, at: soundbite.start, text: note,
                                             provenance: provenance)
            }
            isSaving = false
            dismiss()
        }
    }
}
