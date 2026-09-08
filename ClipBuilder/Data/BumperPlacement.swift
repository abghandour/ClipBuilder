import Foundation

nonisolated enum BumperPlacement: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case intro, outro, anywhere

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}
