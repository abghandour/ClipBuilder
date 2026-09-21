import Foundation

nonisolated struct HighlightCandidate: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable { case whole, subcut }
    var id = UUID()
    var sourceStart: Double
    var sourceEnd: Double
    var title: String
    var reason: String
    var score: Double
    var kind: Kind
    var framing: CropRecipe.Kind = .talker
    var speakerKeys: [String]
    var includesQuestion = false
    var standalone: Bool? = nil
    var duration: Double { sourceEnd - sourceStart }
    var sourceRange: ClosedRange<Double> { min(sourceStart, sourceEnd)...max(sourceStart, sourceEnd) }
}
