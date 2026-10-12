import Foundation
import Testing
@testable import Clip_Builder

@Suite("Source identity file attributes")
struct SourceIdentityAttributesTests {
    @Test func inPlaceRewriteInvalidatesSizeAndModificationTime() throws {
        let temp = try TempDirectory(prefix: "SourceIdentityAttributes")
        let source = temp.url.appendingPathComponent("source.mov")
        try Data("first".utf8).write(to: source)
        let cache = SourceIdentityCache(directory: temp.url.appendingPathComponent("cache"))
        let first = try cache.fingerprint(of: source)
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("second version".utf8))
        try handle.truncate(atOffset: 14)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: source.path)
        let larger = try cache.fingerprint(of: source)
        #expect(first != larger)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("third  version".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: source.path)
        let sameSize = try cache.fingerprint(of: source)
        #expect(larger != sameSize)
        #expect(sameSize == (try ContentHash.fingerprint(of: source)))
    }
}
