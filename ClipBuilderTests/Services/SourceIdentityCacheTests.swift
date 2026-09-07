import Foundation
import Testing
@testable import Clip_Builder

@Suite("Source identity cache")
struct SourceIdentityCacheTests {
    @Test("unchanged rescans and relaunch avoid content reads; changes and force rehash")
    func rescan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("clip.mp4")
        try Data("first".utf8).write(to: file)
        let directory = root.appendingPathComponent("cache")
        var reads = 0
        func scan(_ cache: SourceIdentityCache, force: Bool = false) throws -> [String] {
            let enumerator = FileManager.default.enumerator(
                at: sources, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            var hashes: [String] = []
            while let url = enumerator?.nextObject() as? URL {
                hashes.append(try cache.fingerprint(of: url, force: force) {
                    reads += 1
                    return try ContentHash.fingerprint(of: $0)
                })
            }
            return hashes
        }
        let cache = SourceIdentityCache(directory: directory)
        let first = try scan(cache)
        #expect(reads == 1)
        reads = 0
        #expect(try scan(cache) == first)
        #expect(reads == 0)
        #expect(try scan(SourceIdentityCache(directory: directory)) == first)
        #expect(reads == 0)
        try Data("other".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123456)], ofItemAtPath: file.path)
        #expect(try scan(cache) != first)
        #expect(reads == 1)
        _ = try scan(cache, force: true)
        #expect(reads == 2)
    }
}
