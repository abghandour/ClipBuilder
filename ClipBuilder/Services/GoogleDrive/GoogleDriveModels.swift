import Foundation

nonisolated enum GoogleDriveError: Error, LocalizedError, Equatable {
    case accountMismatch(expected: String)
    case notConfigured, reconnect, quota, notFound, forbidden, offline, cancelled
    case invalidResponse, conflict, inUse, cannotReplaceAsset
    case server(Int)
    case keychain(Int32)

    static func message(for error: Error) -> String {
        if let error = error as? GoogleDriveError { return error.localizedDescription }
        if error is URLError { return GoogleDriveError.offline.localizedDescription }
        if error is CancellationError { return GoogleDriveError.cancelled.localizedDescription }
        return "Google Drive couldn't finish that request. Please try again."
    }

    var errorDescription: String? {
        switch self {
        case .accountMismatch(let expected): "Please sign in with \(expected), the account this profile uses."
        case .notConfigured: "Google Drive isn't available in this copy of Clip Builder."
        case .reconnect: "Please sign in to Google again to continue."
        case .quota: "Google Drive is out of space or busy. Try again later."
        case .notFound: "That file is no longer in Google Drive."
        case .forbidden: "You don't have permission to change that in Google Drive. Ask its owner for edit access."
        case .offline: "You appear to be offline. We'll retry when you're back."
        case .cancelled: "Google sign-in was cancelled."
        case .invalidResponse: "Google Drive couldn't finish that request. Please try again."
        case .cannotReplaceAsset: "cannot replace (not created by Clip Builder)"
        case .inUse: "This video is being used. Close its previews and wait for its other work to finish."
        case .conflict: "This file has changed. Please try again to get the latest copy."
        case .server: "Google Drive is having trouble. Please try again later."
        case .keychain: "Your connection couldn't be saved securely on this Mac. Please try again."
        }
    }
}

nonisolated struct DriveFile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var mimeType: String = "video/mp4"
    var size: String?
    var modifiedTime: String?
    var thumbnailLink: String?
    var webViewLink: String?
    var shared: Bool?
    var ownedByMe: Bool?
    var md5Checksum: String?
    var version: String?
    var trashed: Bool?
    var capabilities: DriveCapabilities?
    var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
    var byteCount: Int64 { Int64(size ?? "") ?? 0 }
    var link: String { webViewLink ?? "https://drive.google.com/file/d/\(id)/view" }
    var isShared: Bool { shared == true || ownedByMe == false }
    /// Unknown capabilities (root, shared-drive stubs) are treated as writable; the server decides.
    var canAddChildren: Bool { capabilities?.canAddChildren != false }
}

nonisolated struct DriveCapabilities: Codable, Hashable, Sendable {
    var canAddChildren: Bool?
}

nonisolated struct DrivePage: Decodable, Sendable {
    var files: [DriveFile]
    var nextPageToken: String?
}

nonisolated struct DriveSharedDrive: Decodable, Identifiable, Sendable {
    var id: String
    var name: String
}

nonisolated struct DriveMedia: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case source, output }
    var kind: Kind
    var recordID: Int64
    var path: String
    var fileID: String?
    var link: String?
    var offloaded: Bool = false
    var shared: Bool = false
    var id: String { "\(kind.rawValue):\(recordID)" }
}

extension VideoRecord {
    nonisolated var driveMedia: DriveMedia {
        DriveMedia(
            kind: .source, recordID: id, path: path, fileID: driveFileID,
            link: driveLink, offloaded: driveOffloaded, shared: driveShared)
    }
}
extension GeneratedVideoRecord {
    nonisolated var driveMedia: DriveMedia {
        DriveMedia(
            kind: .output, recordID: id, path: path, fileID: driveFileID,
            link: driveLink, offloaded: driveOffloaded, shared: driveShared)
    }
}
