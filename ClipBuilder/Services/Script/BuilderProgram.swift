import Foundation

nonisolated enum BuilderProgram: Sendable, Equatable {
    /// Confirm Library work, then parse the frozen request once more.
    case deferred(prerequisites: [BuilderScriptStep])
    case script([BuilderScriptStep])
    case find(SceneFilter, presentation: String)
    case unrecognised([String])
}
