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
enum UpdateService {
    static let repo = "abghandour/ClipBuilder"
    static let releasesPage = URL(string: "https://github.com/abghandour/ClipBuilder/releases")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The latest release if it is newer than the running app, nil when up
    /// to date. Skips drafts/prereleases (the API's `latest` already does).
    static func checkForUpdate() async throws -> AppUpdate? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!,
                                 timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.badResponse
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard currentVersion.compare(version, options: .numeric) == .orderedAscending else {
            return nil
        }
        guard let pkg = release.assets.first(where: { $0.name.hasSuffix(".pkg") }) else {
            throw UpdateError.noInstallerAsset(version: version)
        }
        return AppUpdate(version: version,
                         releaseName: release.name ?? "Clip Builder \(version)",
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

    /// Open the downloaded pkg in Installer.app. The installer replaces the
    /// app in place; the user relaunches when it finishes.
    static func launchInstaller(at url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - GitHub API payloads

    private struct Release: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name, body, assets
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
