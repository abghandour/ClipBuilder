import Foundation
import AppKit

nonisolated enum UpdateError: Error, CustomStringConvertible {
    case badResponse
    case noInstallerAsset(version: String)

    var description: String {
        switch self {
        case .badResponse:
            return "GitHub did not return the latest release"
        case .noInstallerAsset(let version):
            return "Release \(version) has no installer package"
        }
    }
}

/// The outcome of an update check, presented as one alert by the main window.
enum UpdateCheckResult {
    case updateAvailable(AppUpdate)
    case upToDate
}

/// A newer release found on GitHub, ready to be downloaded.
struct AppUpdate {
    let version: String
    let releaseName: String
    let notes: String
    let pkgURL: URL
    let pkgName: String
}

/// Checks the GitHub releases feed for a newer version and downloads the
/// installer pkg. The app ships as a notarized pkg on GitHub releases, so
/// "installing" an update means handing the downloaded pkg to Installer.app.
nonisolated enum UpdateService {
    static let repo = "abghandour/ClipBuilder"
    static let releasesPage = URL(string: "https://github.com/abghandour/ClipBuilder/releases")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The newest release of this channel if it is newer than the running
    /// app, nil when up to date. Stable asks for `latest`, which skips
    /// prereleases (an unblessed release); the beta lists the newest
    /// releases and takes the first that is not a draft.
    static func checkForUpdate(channel: AppChannel = .current) async throws -> AppUpdate? {
        let path = channel.takesPrereleases ? "releases?per_page=5" : "releases/latest"
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/\(path)")!,
                                 timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.badResponse
        }
        return try update(from: data, channel: channel, currentVersion: currentVersion)
    }

    /// The update a feed response offers this channel: `data` is one release
    /// (stable) or a list (beta).
    static func update(from data: Data, channel: AppChannel, currentVersion: String) throws -> AppUpdate? {
        let decoder = JSONDecoder()
        let releases: [Release]
        if channel.takesPrereleases {
            releases = try decoder.decode([Release].self, from: data)
        } else {
            releases = [try decoder.decode(Release.self, from: data)]
        }
        guard let release = releases.first(where: { !$0.draft && (channel.takesPrereleases || !$0.prerelease) }) else {
            return nil
        }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard currentVersion.compare(version, options: .numeric) == .orderedAscending else {
            return nil
        }
        guard let pkg = release.assets.first(where: { channel.isPkgAsset($0.name) }) else {
            throw UpdateError.noInstallerAsset(version: version)
        }
        return AppUpdate(version: version,
                         releaseName: release.name ?? "\(channel.displayName) \(version)",
                         notes: release.body ?? "",
                         pkgURL: pkg.browserDownloadURL,
                         pkgName: pkg.name)
    }

    /// Download the update's pkg into the temporary directory and return
    /// its local URL. Reuses a finished download from the same session.
    static func downloadInstaller(_ update: AppUpdate) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(update.pkgName)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let (temporary, response) = try await URLSession.shared.download(from: update.pkgURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.badResponse
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Open the downloaded pkg in Installer.app and return once Installer is
    /// actually running. Launch Services completes the open asynchronously,
    /// so quitting right after a fire-and-forget `open` could cut the launch
    /// short and leave the user with nothing on screen. The installer
    /// replaces the app in place; the user relaunches when it finishes.
    static func launchInstaller(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - GitHub API payloads

    private struct Release: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let assets: [Asset]
        var draft = false
        var prerelease = false

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name, body, assets, draft, prerelease
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try container.decode(String.self, forKey: .tagName)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            body = try container.decodeIfPresent(String.self, forKey: .body)
            assets = try container.decode([Asset].self, forKey: .assets)
            draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
            prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}
