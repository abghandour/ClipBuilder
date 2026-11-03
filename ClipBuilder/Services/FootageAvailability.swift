import Foundation
import Synchronization

/// One admission rule for Builder renders and previews, including scene-backed
/// clips saved before a teammate's footage arrived on this Mac.
nonisolated enum FootageAvailability {
    private static let snapshot = Mutex<[String: Bool]>([:])
    /// Whether the file itself is on this Mac, as of the last hydration.
    private static let local = Mutex<[String: Bool]>([:])

    /// UI reads never stat files. Unknown paths are admitted until hydration or
    /// the media resolver checks them; nil paths are never admitted.
    static func isPresent(path: String?) -> Bool {
        guard let path, !path.isEmpty, !path.hasPrefix("/.clipbuilder-unavailable/") else { return false }
        return snapshot.withLock { $0[path] ?? true }
    }

    /// The file is on this Mac (a Drive copy that was never downloaded, or
    /// was offloaded, is not). Only the Sources screen lists footage that
    /// fails this; everywhere else such footage is hidden. Unknown paths are
    /// admitted until hydration, like `isPresent`.
    static func isLocal(path: String?) -> Bool {
        guard let path, !path.isEmpty, !path.hasPrefix("/.clipbuilder-unavailable/") else { return false }
        return local.withLock { $0[path] ?? true }
    }

    @discardableResult
    static func refresh(path: String?, driveFileID: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let downloaded = isDownloaded(path: path)
        let available = downloaded || !(driveFileID ?? "").isEmpty
        snapshot.withLock { $0[path] = available }
        local.withLock { $0[path] = downloaded }
        return available
    }

    /// Call on the Database/media actor, never from a view body.
    static func isDownloaded(path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }

    static func missingSource(document: TimelineDocument, scenes: [SceneRecord]) -> String? {
        let byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for clip in document.videoTrack where !clip.bumper {
            if let id = clip.sceneID, let scene = byID[id] {
                if !scene.isPresent { return scene.videoFilename }
            } else if let path = clip.videoFile, !path.isEmpty {
                if !isPresent(path: path) { return URL(fileURLWithPath: path).lastPathComponent }
            }
            // An unresolved legacy scene clip has always been skipped by the
            // renderer when it has no explicit videoFile fallback.
        }
        return nil
    }

    static func requireSources(document: TimelineDocument, scenes: [SceneRecord]) throws {
        if let name = missingSource(document: document, scenes: scenes) {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "\(name): Not on this Mac. Download or import the source file before rendering."])
        }
    }
}
