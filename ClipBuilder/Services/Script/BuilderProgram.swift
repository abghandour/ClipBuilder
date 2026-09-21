import Foundation

nonisolated enum BuilderProgram: Sendable, Equatable {
    /// Confirm Library work, then parse the frozen request once more.
    case deferred(prerequisites: [BuilderScriptStep])
    case podcastHighlights(maxSeconds: Double?, maxCount: Int? = nil)
    case script([BuilderScriptStep])
    case find(SceneFilter, presentation: String)
    case assistedFind(request: String, unresolved: [String])
    case unrecognised([String])
}
