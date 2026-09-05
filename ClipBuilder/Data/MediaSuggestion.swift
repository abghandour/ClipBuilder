import Foundation

nonisolated struct MediaSuggestion: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable { case photo, bRoll }
    var kind: Kind
    var path: String?
    var sceneID: Int64?
    var atTime: Double
    var reason: String
    var id: String { "\(kind.rawValue)|\(path ?? "")|\(sceneID ?? 0)|\(atTime)" }
}
