import Foundation

nonisolated struct AssetSyncEntry: Equatable, Sendable {
    var size: Int64 = 0
    var modifiedDate: Date = .distantPast
    var md5: String?
    var driveID: String?
    var isFolder = false

    init(
        size: Int64 = 0, modifiedDate: Date = .distantPast, md5: String? = nil,
        driveID: String? = nil, isFolder: Bool = false
    ) {
        self.size = size
        self.modifiedDate = modifiedDate
        self.md5 = md5
        self.driveID = driveID
        self.isFolder = isFolder
    }

    init(_ file: DriveFile) {
        size = file.byteCount
        modifiedDate = Self.date(file.modifiedTime) ?? .distantPast
        md5 = file.md5Checksum
        driveID = file.id
        isFolder = file.isFolder
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
