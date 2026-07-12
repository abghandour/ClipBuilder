import Foundation

/// Errors surfaced by the Instagram integration. Keep messages actionable —
/// scraping failures always suggest the settings fix.
nonisolated enum InstagramError: Error, CustomStringConvertible {
    case toolMissing(String)
    case fetchFailed(String)
    case parseFailed(String)
    case notDownloaded

    var description: String {
        switch self {
        case .toolMissing(let tool):
            return "\(tool) not found. Install it with: brew install \(tool)"
        case .fetchFailed(let detail):
            return "Instagram fetch failed: \(detail)"
        case .parseFailed(let detail):
            return "Could not read Instagram's response: \(detail)"
        case .notDownloaded:
            return "The reel video hasn't been downloaded yet"
        }
    }
}

nonisolated struct IGProfileInfo: Sendable {
    var username: String
    var displayName: String?
    var igUserID: String?
    var followers: Int?
}

/// Provider-neutral fetch result for one reel/video.
nonisolated struct IGMediaItem: Sendable {
    var mediaID: String
    var mediaType: String = "reel"
    var caption: String = ""
    var permalink: String?
    var postedAt: Date?
    var duration: Double?
    var stats = IGStats()
    var thumbnailRemoteURL: String?
    var videoRemoteURL: String?          // Graph media_url when present

    var statsJSON: String {
        (try? JSONEncoder().encode(stats)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// The isolation boundary: everything Instagram-shaped (URL formats, JSON
/// quirks, scraping breakage) lives behind this protocol. The app only sees
/// IGMediaItem/IGStats.
nonisolated protocol InstagramProvider: Sendable {
    var sourceName: String { get }       // "ytdlp" | "graph"
    func fetchProfile(username: String,
                      log: @escaping @Sendable (String) -> Void) async throws -> IGProfileInfo
    func fetchReels(username: String, limit: Int,
                    log: @escaping @Sendable (String) -> Void) async throws -> [IGMediaItem]
    func downloadThumbnail(_ item: IGMediaItem, to destination: URL) async throws
    func downloadVideo(_ item: IGMediaItem, to destination: URL,
                       log: @escaping @Sendable (String) -> Void) async throws
}
