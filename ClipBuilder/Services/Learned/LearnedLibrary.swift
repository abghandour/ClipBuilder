import Foundation
import Synchronization

/// Inject the app root (the directory containing `learned`) in tests.
nonisolated struct LearnedLibrary: Sendable {
    var root: URL
    var profile: String?
    init(root: URL = ProfileStore.profilesDirectory, profile: String? = nil) {
        self.root = root
        self.profile = profile
    }
    private var registryURL: URL? {
        profile.map { directory.appendingPathComponent(".profile-" + LearnedPreferences.stableID($0) + ".json") }
    }
    private func registered() -> Set<String> {
        guard let registryURL, let data = try? Data(contentsOf: registryURL) else { return [] }
        return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
    }
    var directory: URL { root.appendingPathComponent("learned", isDirectory: true) }

    func documents() -> [LearnedPreferences] {
        let children = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let allowed = profile == nil ? nil : registered()
        return children.sorted { $0.path < $1.path }.compactMap { child in
            if let allowed, !allowed.contains(child.lastPathComponent) { return nil }
            let file = child.appendingPathComponent("document.json")
            guard let data = try? Data(contentsOf: file), let document = try? decode(data),
                  child.lastPathComponent == document.contributor else { return nil }
            return document
        }
    }

    func decode(_ data: Data) throws -> LearnedPreferences {
        guard data.count <= 2_000_000 else { throw LearnedRedaction.Failure.invalidDocument }
        try LearnedRedaction.validateSchema(data)
        return try LearnedRedaction.apply(JSONDecoder().decode(LearnedPreferences.self, from: data), publishing: true)
    }

    func frameURL(_ name: String, contributor: String) throws -> URL {
        guard LearnedRedaction.isFrame(name, contributor: contributor) else { throw LearnedRedaction.Failure.invalidDocument }
        let url = root.appendingPathComponent(name)
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw LearnedRedaction.Failure.invalidDocument
        }
        return url
    }

    func install(_ document: LearnedPreferences, frames: [String: Data]) throws {
        let safe = try LearnedRedaction.apply(document, publishing: true)
        let folder = directory.appendingPathComponent(safe.contributor, isDirectory: true)
        guard folder.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else {
            throw LearnedRedaction.Failure.invalidDocument
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in safe.frameNames {
            guard let data = frames[name], data.starts(with: [0xff, 0xd8, 0xff]) else {
                throw LearnedRedaction.Failure.invalidDocument
            }
            let target = try frameURL(name, contributor: safe.contributor)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        try JSONEncoder().encode(safe).write(to: folder.appendingPathComponent("document.json"), options: .atomic)
        if let registryURL {
            var names = registered()
            names.insert(safe.contributor)
            try JSONEncoder().encode(names).write(to: registryURL, options: .atomic)
        }
        LearnedCache.invalidate()
    }
}

nonisolated enum LearnedCache {
    struct Entry: Sendable { var key: String; var lines: [LearnedMerge.Line] }
    private static let entries = Mutex<[String: Entry]>([:])
    static func invalidate(profile: String? = nil) {
        entries.withLock { if let profile { $0[profile] = nil } else { $0.removeAll() } }
    }
    static func merged(profile: BrandProfile, local: LearnedPreferences,
                       contributors: [LearnedPreferences]) -> [LearnedMerge.Line] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = LearnedPreferences.stableID(String(decoding: (try? encoder.encode(local)) ?? Data(), as: UTF8.self)
            + String(decoding: (try? encoder.encode(contributors)) ?? Data(), as: UTF8.self)
            + profile.learnedSharing.mutedContributors.sorted().joined(separator: "|"))
        return entries.withLock {
            if let entry = $0[profile.profileName], entry.key == key { return entry.lines }
            let lines = LearnedMerge.merge(local: local, contributors: contributors, muted: profile.learnedSharing.mutedContributors)
            $0[profile.profileName] = Entry(key: key, lines: lines)
            return lines
        }
    }
}
