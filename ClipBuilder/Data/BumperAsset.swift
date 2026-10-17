import Foundation

nonisolated struct BumperAsset: Identifiable, Sendable, Hashable {
    var path: String
    var displayName: String
    var placements: Set<BumperPlacement> = Set(BumperPlacement.allCases)
    var duration: Double?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    /// Identity that travels between Macs: the path inside the Bumpers
    /// library ("Intros/open.mp4"); a file outside it keeps just its name.
    var libraryPath: String { Self.libraryPath(of: path) }

    static func libraryPath(of path: String, root: URL = AssetKind.bumpers.rootURL) -> String {
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : (path as NSString).lastPathComponent
    }

    func clip(at time: Double) -> TimelineClip? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        var clip = TimelineClip()
        clip.bumper = true
        clip.bumperName = displayName
        clip.videoFile = path
        clip.sourceStart = 0
        clip.sourceEnd = duration
        clip.startTime = time
        clip.duration = duration
        clip.captions = "none"
        return clip
    }
}
