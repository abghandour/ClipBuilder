import Foundation

nonisolated enum BuilderProgram: Sendable, Equatable {
    case script([BuilderScriptStep])
    case find(SceneFilter, presentation: String)
    case unrecognised([String])
}
