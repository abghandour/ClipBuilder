import Foundation

nonisolated struct CriticBrief: Codable, Sendable, Hashable {
    static let version = 1
    var key: String
    var builtAt: Date
    var rules: String
    var exemplars: [Exemplar]
    var provider: String?
    var model: String?

    struct Exemplar: Codable, Sendable, Hashable {
        var id: String
        var label: String
        var why: String
        var duration: Double
        var traits: ReelTraits?
        var sheetPath: String

        var summary: String {
            let pacing = traits.map { ", \(Int($0.cutsPerMinute.rounded())) cuts/min" } ?? ""
            return "\(label): \(String(format: "%.1f", duration))s\(pacing), \(why)"
        }
    }
}
