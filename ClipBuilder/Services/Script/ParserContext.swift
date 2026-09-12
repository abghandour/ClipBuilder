import Foundation

/// Value snapshot of the vocabulary and editing context at Run, never a live lookup.
nonisolated struct ParserContext: Sendable {
    var library: ScriptLibrarySnapshot
    var document: TimelineDocument
    var selectedClipID: UUID?
    /// Whatever is selected in the timeline, clip or not.
    var selection: TimelineSelection?
    var playhead: Double
    var focusedTrack: Int

    @MainActor
    init(library: ScriptLibrarySnapshot, model: BuilderTimelineModel) {
        self.library = library
        document = model.document
        selection = model.selection
        if case .clip(let id) = model.selection { selectedClipID = id }
        playhead = model.playhead
        focusedTrack = model.focusedTrack ?? 0
    }
}
