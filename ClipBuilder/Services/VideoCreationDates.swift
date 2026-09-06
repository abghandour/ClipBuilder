import AVFoundation
import Foundation

/// File and metadata I/O executes on this actor, never the UI actor.
actor VideoCreationDates {
    private let filesystemDate: @Sendable (URL) throws -> Date?
    private let metadataDate: @Sendable (URL) async -> Date?

    init(
        filesystemDate: @escaping @Sendable (URL) throws -> Date? = {
            try $0.resourceValues(forKeys: [.creationDateKey]).creationDate
        },
        metadataDate: @escaping @Sendable (URL) async -> Date? = { await VideoCreationDates.mediaDate($0) }
    ) {
        self.filesystemDate = filesystemDate
        self.metadataDate = metadataDate
    }

    func resolve(path: String, discoveredAt: String?) async -> String {
        let url = URL(fileURLWithPath: path)
        if let date = try? filesystemDate(url) { return date.ISO8601Format() }
        if let date = await metadataDate(url) { return date.ISO8601Format() }
        return (Self.parse(discoveredAt) ?? Date()).ISO8601Format()
    }

    nonisolated private static func mediaDate(_ url: URL) async -> Date? {
        // Do not restore off-loaded media merely to discover its date.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate) {
            if let date = try? await item.load(.dateValue) { return date }
            if let value = try? await item.load(.stringValue) { return parse(value) }
        }
        return nil
    }

    nonisolated static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: value) { return date }
        // Legacy SQLite datetime('now') values are UTC without an offset.
        let sqlite = DateFormatter()
        sqlite.locale = Locale(identifier: "en_US_POSIX")
        sqlite.timeZone = TimeZone(secondsFromGMT: 0)
        sqlite.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sqlite.date(from: value)
    }
}
