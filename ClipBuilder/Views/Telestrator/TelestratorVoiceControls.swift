import AppKit
import SwiftUI

/// Where a voice over recorded in the drawing editor belongs: the Express
/// reel's recordings, and the clip the editor was opened from.
struct TelestratorVoice: Equatable {
    var owner: VoiceOverLibrary.Owner
    var videoID: Int64
}

/// Record Voice Over in the drawing editor: the clip plays in real time with
/// the drawing in it while the microphone records. The recording joins the
/// reel's Voice Over list, anchored to the clip's first frame.
struct TelestratorVoiceControls: View {
    @Environment(AppStore.self) private var store
    let editor: TelestratorEditor
    let videoURL: URL
    let voice: TelestratorVoice
    /// Source seconds the recording in progress started over.
    @State private var recordStart: Double?

    private var library: VoiceOverLibrary { store.voiceOver }
    private var recording: Bool { editor.playMode == .voice }
    private var clip: ClosedRange<Double> { editor.clipRange ?? editor.drawing.time...editor.footageEnd }
    private var takes: [VoiceTake] {
        guard library.owner == voice.owner else { return [] }
        return library.takes.filter { $0.videoID == voice.videoID && clip.contains($0.sourceTime) }
    }
    private var spokenLanguage: String {
        ProjectLanguageResolver.resolve(project: nil, profile: store.activeProfile).spoken.first ?? ""
    }
    private var blocked: String? {
        switch library.recorder.access {
        case .unavailable: return "This build cannot use the microphone: it has no microphone permission text."
        case .denied: return "Clip Builder is not allowed to use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
        default: break
        }
        if editor.drawing.figures.isEmpty { return "Draw a figure first: the recording plays over the clip with the drawing in it." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { if recording { stop() } else { begin() } } label: {
                    Label(recording ? "Stop Recording \(WizardPreviewClips.clock(library.recorder.elapsed))" : "Record Voice Over",
                          systemImage: recording ? "stop.fill" : "mic.fill")
                        .monospacedDigit().lineLimit(1).fixedSize()
                        .foregroundStyle(recording ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                }
                .disabled(!recording && (blocked != nil || !editor.ready || editor.isDragging || editor.isPlaying
                                         || library.owner != voice.owner || store.database == nil))
                .help("Plays this clip in real time with the drawing in it and records your voice over it")
                LevelMeter(level: library.recorder.isRecording ? library.recorder.level : 0)
                Text(blocked ?? (recording ? "Talk over the clip. It stops at the end of the clip, or press Stop."
                                 : "The clip plays in real time with the drawing while you talk. A recording is saved as it is made, also if you cancel the drawing."))
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if library.recorder.access == .denied {
                    Button("Open Microphone Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .lineLimit(1).fixedSize()
                }
            }
            if let message = library.message {
                Text(message).font(.callout).foregroundStyle(.orange)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(takes) { take in
                HStack(spacing: 8) {
                    Button(library.auditioning == take.id ? "Stop" : "Listen",
                           systemImage: library.auditioning == take.id ? "stop.fill" : "play.fill") {
                        if let database = store.database { library.toggleAudition(take, database: database) }
                    }
                    .labelStyle(.iconOnly)
                    .help(library.auditioning == take.id ? "Stop this recording" : "Listen to this recording")
                    Text(String(format: "%.1f s", take.duration))
                        .monospacedDigit().lineLimit(1).fixedSize()
                    Text(take.state == .pending ? "Writing its caption…" : take.text.isEmpty ? "No words heard" : take.text)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        if let database = store.database { library.delete(take, database: database) }
                    }
                    .labelStyle(.iconOnly)
                    .help("Delete this recording")
                }
                .disabled(recording)
            }
        }
        .task(id: voice) {
            library.recorder.refreshAccess()
            await library.load(voice.owner, database: store.database, language: spokenLanguage, ai: store.ai)
        }
        .onDisappear {
            // Closed mid-recording: nothing is kept.
            if recordStart != nil { library.cancelRecording() }
            recordStart = nil
            library.stopAudition()
        }
    }

    private func begin() {
        guard let database = store.database, blocked == nil else { return }
        let library = library
        let start = clip.lowerBound
        editor.play(url: videoURL, mode: .voice, ready: {
            // The picture is in place: the microphone starts with the clock.
            guard await library.beginRecording(database: database) else { return false }
            // Stopped while the system asked for the microphone: nothing to record.
            guard !Task.isCancelled else { library.cancelRecording(); return false }
            recordStart = start
            return true
        }, ended: { finish() })
    }

    private func stop() {
        editor.stopPlayback()
        finish()
    }

    /// Keeps the recording, anchored to the clip's first frame so it follows
    /// that footage in the reel.
    private func finish() {
        guard let start = recordStart, let database = store.database else {
            library.cancelRecording()
            recordStart = nil
            return
        }
        recordStart = nil
        library.finishRecording(anchor: (videoID: voice.videoID, sourceTime: start, holdOffset: nil, occurrence: 0),
                                reelTime: 0, language: spokenLanguage, captionLanguage: nil,
                                ai: store.ai, database: database)
    }
}
