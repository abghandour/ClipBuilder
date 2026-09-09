import Foundation

nonisolated enum AssetSyncKind: String, CaseIterable, Codable, Sendable {
    case music, fonts, images, bumpers, overlays
    case screenCrops = "screen_crops"

    var folderName: String { rawValue }
    var assetKind: AssetKind? { AssetKind(rawValue: rawValue) }
    var allowedExtensions: Set<String> { assetKind?.allowedExtensions ?? ["json"] }

    static func accepts(_ path: String, isFolder: Bool) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first, let kind = Self(rawValue: String(first)),
            parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") && !$0.contains("\0") })
        else { return false }
        return isFolder
            || (parts.count > 1 && kind.allowedExtensions.contains((path as NSString).pathExtension.lowercased()))
    }
}
