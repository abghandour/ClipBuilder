import Foundation

/// What the Text Look Wizard saved from one reference file. The job result
/// carries it to the review sheet, where the user can rename each item
/// before going back to the studio.
nonisolated struct TextLookImport: Equatable, Sendable {
    enum Kind: String, Sendable {
        case overlay, caption, nameTag

        var label: String {
            switch self {
            case .overlay: "Overlay template"
            case .caption: "Caption style"
            case .nameTag: "Name tag style"
            }
        }
    }

    struct Item: Identifiable, Equatable, Sendable {
        var kind: Kind
        /// Template name for an overlay (its file), style UUID otherwise.
        var id: String
        var name: String
    }

    var items: [Item]
    /// Targets the user asked for that the model did not find.
    var missing: [String] = []
}
