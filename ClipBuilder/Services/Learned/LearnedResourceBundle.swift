import Foundation

nonisolated enum LearnedResourceBundle {
    /// `root` is the resource bundle root; names are identical to Drive names.
    static func pack(_ builds: [LearnedDocumentBuilder.Build], root: URL) throws -> Int {
        var count = 0
        for build in builds {
            let document = try LearnedRedaction.apply(build.document, publishing: true)
            let folder = root.appendingPathComponent("learned", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in document.frameNames {
                guard let data = build.frames[name] else { throw LearnedRedaction.Failure.invalidDocument }
                let target = try LearnedLibrary(root: root).frameURL(name, contributor: document.contributor)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                count += 1
            }
            try JSONEncoder().encode(document).write(to: folder.appendingPathComponent(document.contributor + ".json"), options: .atomic)
            count += 1
        }
        return count
    }

    /// Drive and bundle import both terminate at LearnedLibrary.install.
    static func unpack(root: URL, library: LearnedLibrary) throws -> Int {
        let folder = root.appendingPathComponent("learned", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var count = 0
        for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "json" {
            guard file.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/") else {
                throw LearnedRedaction.Failure.invalidDocument
            }
            let document = try library.decode(Data(contentsOf: file))
            guard file.lastPathComponent == document.contributor + ".json" else { throw LearnedRedaction.Failure.invalidDocument }
            var frames: [String: Data] = [:]
            for name in document.frameNames {
                let source = try LearnedLibrary(root: root).frameURL(name, contributor: document.contributor)
                frames[name] = try Data(contentsOf: source)
            }
            // Older imports cannot replace a newer contributor snapshot.
            let existing = library.documents().first { $0.contributor == document.contributor }
            if let existing, (existing.sections.map(\.updatedAt).max() ?? .distantPast)
                > (document.sections.map(\.updatedAt).max() ?? .distantPast) { continue }
            try library.install(document, frames: frames)
            count += 1
        }
        return count
    }
}
