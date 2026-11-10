import SwiftUI

/// Asks which word timing a Transcribe uses, when the videos can use more
/// than one. Lives on the root view; sheets ask in their own dialog.
struct TranscriptionModelChoiceDialog: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.controlActiveState) private var activeState
    /// This window: every main window shares the store, one of them asks.
    @State private var windowID = UUID()

    static let message = "Precise re-times each Portuguese word against the audio after Apple's transcription. Speech in other languages keeps Apple's word times."

    private var presentsHere: Bool { store.transcriptionChoiceRequest?.presenter == windowID }

    func body(content: Content) -> some View {
        content
            .task(id: store.transcriptionChoiceRequest?.id) {
                guard store.transcriptionChoiceRequest?.presenter == nil else { return }
                // The window the user clicked in is key and claims at once;
                // another only if nobody has, so a request is never left unasked.
                if activeState != .key { try? await Task.sleep(for: .milliseconds(300)) }
                if !Task.isCancelled, store.transcriptionChoiceRequest?.presenter == nil {
                    store.transcriptionChoiceRequest?.presenter = windowID
                }
            }
            .confirmationDialog("Which transcription model?", isPresented: Binding(
                get: { presentsHere },
                set: { if !$0, presentsHere { store.dismissTranscriptionChoice() } }
            ), presenting: store.transcriptionChoiceRequest) { request in
                ForEach(request.options) { timing in
                    Button(timing.label) { store.resolveTranscriptionChoice(request, wordTiming: timing) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text((request.videoIDs.count > 1 ? "For \(request.videoIDs.count) videos. " : "") + Self.message)
            }
    }
}
