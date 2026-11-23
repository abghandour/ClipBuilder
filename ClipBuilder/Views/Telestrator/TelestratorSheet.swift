import CoreGraphics
import Foundation
import SwiftUI

/// Standalone editor. Its parent owns presentation and persistence.
struct TelestratorSheet: View {
    let videoURL: URL
    let aspect: CGFloat
    let visibleRect: CGRect?
    let lockTime: Bool
    /// Set where a voice over can be recorded over the clip (Express).
    let voice: TelestratorVoice?
    /// Nil when saved; otherwise the reason. The sheet stays open on a failure.
    let onSave: (Telestration?) async -> String?
    @State private var saving = false
    @State private var saveError: String?
    private let hadDrawing: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var editor: TelestratorEditor
    @Environment(AppStore.self) private var store: AppStore?

    init(videoURL: URL, initialTime: Double, duration: Double, aspect: CGFloat,
         visibleRect: CGRect? = nil, range: ClosedRange<Double>? = nil, clipRange: ClosedRange<Double>? = nil,
         existing: Telestration? = nil, lockTime: Bool = false, allowsMotion: Bool = true,
         voice: TelestratorVoice? = nil,
         onSave: @escaping (Telestration?) async -> String?) {
        self.videoURL = videoURL
        self.aspect = aspect
        self.visibleRect = visibleRect
        self.lockTime = lockTime
        self.voice = voice
        self.onSave = onSave
        hadDrawing = existing != nil
        _editor = State(initialValue: TelestratorEditor(initialTime: initialTime, duration: duration,
                                                       aspect: aspect, existing: existing, range: range,
                                                       clipRange: clipRange, lockTime: lockTime,
                                                       allowsMotion: allowsMotion))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Draw on the picture", systemImage: "pencil.tip")
                .font(.title2.weight(.semibold)).lineLimit(1).fixedSize()
            HStack(alignment: .top, spacing: 12) {
                TelestratorCanvas(editor: editor, aspect: aspect, visibleRect: visibleRect)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay(alignment: .topLeading) { recordingBadge }
                TelestratorFigureList(editor: editor).frame(width: 220)
            }
            .frame(maxHeight: .infinity)
            if !lockTime { frameControls }
            TelestratorToolbar(editor: editor)
            Divider()
            TelestratorTimingControls(editor: editor)
            if let voice, store != nil {
                Divider()
                TelestratorVoiceControls(editor: editor, videoURL: videoURL, voice: voice)
            }
            if let saveError {
                Label("Not saved: \(saveError)", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 650)
        // Nothing is edited or closed under a save that is still landing.
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .modalCloseButton { if !saving { dismiss() } }
        .onDeleteCommand { if !editor.isPlaying, !saving { editor.deleteSelected() } }
        .task(id: editor.drawing.time) { await editor.load(url: videoURL) }
        .onDisappear { editor.stopPlayback() }
    }

    /// Over the picture while the microphone is recording.
    @ViewBuilder private var recordingBadge: some View {
        if editor.playMode == .voice, let recorder = store?.voiceOver.recorder, recorder.isRecording {
            Label("REC \(WizardPreviewClips.clock(recorder.elapsed))", systemImage: "record.circle.fill")
                .font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1).fixedSize()
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.red, in: Capsule())
                .padding(10)
                .accessibilityLabel("Recording voice over")
        }
    }

    private var frameControls: some View {
        HStack(spacing: 8) {
            Button("Previous frame", systemImage: "backward.frame") { editor.step(-1) }
                .labelStyle(.iconOnly).help("Previous frame")
                .disabled(editor.drawing.time <= editor.firstFrameTime)
            Button("Next frame", systemImage: "forward.frame") { editor.step(1) }
                .labelStyle(.iconOnly).help("Next frame")
                .disabled(editor.drawing.time >= editor.lastFrameTime)
            Slider(value: Binding(get: { editor.drawing.time }, set: { editor.setTime($0) }),
                   in: editor.firstFrameTime...max(editor.lastFrameTime, editor.firstFrameTime + 0.001), onEditingChanged: editor.controlEditing)
                .accessibilityLabel("Source moment")
                .disabled(editor.lastFrameTime <= editor.firstFrameTime)
            Text("\(editor.drawing.time, format: .number.precision(.fractionLength(3))) s")
                .monospacedDigit().lineLimit(1).fixedSize()
        }
        .disabled(editor.isDragging || editor.isPlaying)
    }

    private var footer: some View {
        HStack {
            Button { editor.togglePlay(url: videoURL) } label: {
                Label(editor.playMode == .drawing ? "Stop" : "Play",
                      systemImage: editor.playMode == .drawing ? "stop.fill" : "play.fill")
                    .lineLimit(1).fixedSize()
            }
            .disabled(editor.drawing.figures.isEmpty || !editor.ready || editor.isDragging || editor.playMode == .voice)
            .help(editor.drawing.motion == nil ? "Play the drawing on the paused picture"
                  : "Play the drawing over the picture at \(TelestrationPlayback.label(editor.drawing.motion))")
            if hadDrawing {
                Button(role: .destructive) { commit(nil) } label: {
                    Text("Delete drawing").lineLimit(1).fixedSize()
                }
            }
            Spacer()
            Button { dismiss() } label: { Text("Cancel").lineLimit(1).fixedSize() }
                .keyboardShortcut(.cancelAction)
            if saving { ProgressView().controlSize(.small) }
            Button { commit(editor.drawing) } label: { Text("Save").lineLimit(1).fixedSize() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(editor.drawing.figures.isEmpty || editor.isDragging || saving)
        }
    }

    /// The drawing stays in the sheet until the save is known to have landed.
    private func commit(_ drawing: Telestration?) {
        guard !saving else { return }
        saving = true
        saveError = nil
        Task {
            let failure = await onSave(drawing)
            saving = false
            if let failure { saveError = failure } else { dismiss() }
        }
    }
}

#Preview {
    TelestratorSheet(videoURL: URL(fileURLWithPath: "/nonexistent/telestrator-preview.mov"),
                     initialTime: 0, duration: 10, aspect: 16.0 / 9.0) { _ in nil }
}
