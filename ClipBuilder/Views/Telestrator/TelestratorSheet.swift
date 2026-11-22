import CoreGraphics
import Foundation
import SwiftUI

/// Standalone editor. Its parent owns presentation and persistence.
struct TelestratorSheet: View {
    let videoURL: URL
    let aspect: CGFloat
    let visibleRect: CGRect?
    let onSave: (Telestration?) -> Void
    private let hadDrawing: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var editor: TelestratorEditor

    init(videoURL: URL, initialTime: Double, duration: Double, aspect: CGFloat,
         visibleRect: CGRect? = nil, existing: Telestration? = nil, onSave: @escaping (Telestration?) -> Void) {
        self.videoURL = videoURL
        self.aspect = aspect
        self.visibleRect = visibleRect
        self.onSave = onSave
        hadDrawing = existing != nil
        _editor = State(initialValue: TelestratorEditor(initialTime: initialTime, duration: duration,
                                                       aspect: aspect, existing: existing))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Draw on pause", systemImage: "pencil.tip")
                .font(.title2.weight(.semibold)).lineLimit(1).fixedSize()
            HStack(alignment: .top, spacing: 12) {
                TelestratorCanvas(editor: editor, aspect: aspect, visibleRect: visibleRect)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                TelestratorFigureList(editor: editor).frame(width: 220)
            }
            .frame(maxHeight: .infinity)
            frameControls
            TelestratorToolbar(editor: editor)
            Divider()
            TelestratorTimingControls(editor: editor)
            footer
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 650)
        .modalCloseButton { dismiss() }
        .onDeleteCommand { if editor.playStarted == nil { editor.deleteSelected() } }
        .task(id: editor.drawing.time) { await editor.load(url: videoURL) }
        .task(id: editor.playStarted) {
            guard let start = editor.playStarted else { return }
            do {
                try await Task.sleep(for: .seconds(editor.drawing.duration))
                guard !Task.isCancelled, editor.playStarted == start else { return }
                editor.playStarted = nil
            } catch { /* A second press or dismissal cancels playback. */ }
        }
        .onDisappear { editor.playStarted = nil }
    }

    private var frameControls: some View {
        HStack(spacing: 8) {
            Button("Previous frame", systemImage: "backward.frame") { editor.step(-1) }
                .labelStyle(.iconOnly).help("Previous frame")
                .disabled(editor.drawing.time <= 0)
            Button("Next frame", systemImage: "forward.frame") { editor.step(1) }
                .labelStyle(.iconOnly).help("Next frame")
                .disabled(editor.drawing.time >= editor.lastFrameTime)
            Slider(value: Binding(get: { editor.drawing.time }, set: { editor.setTime($0) }),
                   in: 0...max(editor.lastFrameTime, 0.001), onEditingChanged: editor.controlEditing)
                .accessibilityLabel("Source moment")
                .disabled(editor.lastFrameTime <= 0)
            Text("\(editor.drawing.time, format: .number.precision(.fractionLength(3))) s")
                .monospacedDigit().lineLimit(1).fixedSize()
        }
        .disabled(editor.isDragging || editor.playStarted != nil)
    }

    private var footer: some View {
        HStack {
            Button(action: editor.togglePlay) {
                Label(editor.playStarted == nil ? "Play" : "Stop",
                      systemImage: editor.playStarted == nil ? "play.fill" : "stop.fill")
                    .lineLimit(1).fixedSize()
            }
            .disabled(editor.drawing.figures.isEmpty || !editor.ready || editor.isDragging)
            if hadDrawing {
                Button(role: .destructive) { onSave(nil); dismiss() } label: {
                    Text("Delete drawing").lineLimit(1).fixedSize()
                }
            }
            Spacer()
            Button { dismiss() } label: { Text("Cancel").lineLimit(1).fixedSize() }
                .keyboardShortcut(.cancelAction)
            Button { onSave(editor.drawing); dismiss() } label: { Text("Save").lineLimit(1).fixedSize() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(editor.drawing.figures.isEmpty || editor.isDragging)
        }
    }
}

#Preview {
    TelestratorSheet(videoURL: URL(fileURLWithPath: "/nonexistent/telestrator-preview.mov"),
                     initialTime: 0, duration: 10, aspect: 16.0 / 9.0) { _ in }
}
