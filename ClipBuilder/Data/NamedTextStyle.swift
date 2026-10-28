import Foundation

nonisolated struct NamedTextStyle: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var decor: TextDecor
    var fontFamily: String?
}
