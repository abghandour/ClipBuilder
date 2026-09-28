import Foundation

/// Client-side narrowing and ordering of one loaded Drive listing. Drive's
/// query language cannot filter on video dimensions, so shape and size
/// filters apply to the pages already fetched; folders always stay first.
nonisolated struct DriveBrowserFilter: Equatable, Sendable {
    enum Shape: String, CaseIterable, Sendable {
        case any, wide, tall, square
        var label: String {
            switch self {
            case .any: "Any shape"
            case .wide: "Wide (landscape)"
            case .tall: "Tall (portrait)"
            case .square: "Square"
            }
        }
        var matches: DriveVideoShape? {
            switch self {
            case .any: nil
            case .wide: .wide
            case .tall: .tall
            case .square: .square
            }
        }
    }

    enum Sort: String, CaseIterable, Sendable {
        case name, newest, largest, longest
        var label: String {
            switch self {
            case .name: "Name"
            case .newest: "Newest"
            case .largest: "Largest"
            case .longest: "Longest"
            }
        }
    }

    enum MinimumSize: Int64, CaseIterable, Sendable {
        case any = 0
        case mb100 = 100_000_000
        case mb500 = 500_000_000
        case gb1 = 1_000_000_000
        case gb4 = 4_000_000_000
        var label: String {
            self == .any ? "Any size" : "Over " + ByteCountFormatter.string(fromByteCount: rawValue, countStyle: .file)
        }
    }

    var shape: Shape = .any
    var sort: Sort = .name
    var minimumSize: MinimumSize = .any

    var isActive: Bool { shape != .any || minimumSize != .any }

    struct Result: Equatable, Sendable {
        var files: [DriveFile]
        /// Videos hidden only because Drive has not reported their dimensions yet.
        var unknownShapeHidden: Int
    }

    func apply(to files: [DriveFile]) -> Result {
        var unknownHidden = 0
        var kept = files.filter { file in
            guard !file.isFolder else { return true }
            if minimumSize != .any, file.byteCount < minimumSize.rawValue { return false }
            if let wanted = shape.matches, file.shape != wanted {
                if file.shape == .unknown, file.isVideo { unknownHidden += 1 }
                return false
            }
            return true
        }
        kept.sort { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            if a.isFolder { return Self.nameAscending(a, b) }
            switch sort {
            case .name: return Self.nameAscending(a, b)
            case .newest:
                let (ta, tb) = (a.modifiedTime ?? "", b.modifiedTime ?? "")
                return ta != tb ? ta > tb : Self.nameAscending(a, b)
            case .largest:
                return a.byteCount != b.byteCount ? a.byteCount > b.byteCount : Self.nameAscending(a, b)
            case .longest:
                let (da, db) = (a.durationSeconds ?? -1, b.durationSeconds ?? -1)
                return da != db ? da > db : Self.nameAscending(a, b)
            }
        }
        return Result(files: kept, unknownShapeHidden: unknownHidden)
    }

    private static func nameAscending(_ a: DriveFile, _ b: DriveFile) -> Bool {
        let order = a.name.localizedStandardCompare(b.name)
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }
}
