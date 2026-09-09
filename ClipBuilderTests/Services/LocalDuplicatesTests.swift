import Foundation
import Testing
@testable import Clip_Builder

struct LocalDuplicatesTests {
    @Test func overlappingGroupsMerge() {
        let result = DuplicateFinder.merge([
            .init(videoIDs: [1, 2], keepID: 1, reason: "local"),
            .init(videoIDs: [3, 4], keepID: 4, reason: "model"),
            .init(videoIDs: [2, 3], keepID: 3, reason: "model"),
        ])
        #expect(result.count == 1)
        #expect(result.first?.videoIDs == [1, 2, 3, 4])
        #expect(result.first?.keepID == 1)
    }
    @Test func groupingAndKeeper() {
        let a = LocalDuplicates.Signature(id: 1, size: 100, digest: "same", duration: 10, width: 100, height: 100, hashes: [], created: Date(timeIntervalSince1970: 1))
        var b = a
        b.id = 2
        b.created = Date(timeIntervalSince1970: 2)
        #expect(LocalDuplicates.groups([b, a]).first?.keepID == 1)
        b.digest = "different"
        #expect(LocalDuplicates.groups([a, b]).isEmpty)
        var c = a
        c.digest = nil
        c.hashes = [0, 0, 0, 0, 0]
        b.hashes = [3, 3, 3, 3, 3]
        #expect(LocalDuplicates.matches(b, c))
        b.hashes[4] = UInt64.max
        #expect(!LocalDuplicates.matches(b, c))
    }
}

extension LocalDuplicatesTests {
    @Test func digestReadsHeadAndTail() throws {
        let directory = try TempDirectory(prefix: "LocalDuplicates")
        let bytes = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let a = directory.url.appendingPathComponent("a.mp4")
        let b = directory.url.appendingPathComponent("b.mp4")
        let c = directory.url.appendingPathComponent("c.mp4")
        try bytes.write(to: a)
        try bytes.write(to: b)
        var tail = bytes
        tail[tail.count - 1] ^= 0xFF
        try tail.write(to: c)
        let da = try #require(LocalDuplicates.digest(a))
        #expect(da.0 == bytes.count)
        #expect(LocalDuplicates.digest(b)?.1 == da.1)
        #expect(LocalDuplicates.digest(c)?.1 != da.1)
        #expect(LocalDuplicates.digest(directory.url.appendingPathComponent("missing.mp4")) == nil)
        let small = directory.url.appendingPathComponent("small.mp4")
        try Data("tiny".utf8).write(to: small)
        #expect(LocalDuplicates.digest(small)?.0 == 4)
    }
    @Test func frameHashesNeedMatchingShape() {
        let base = LocalDuplicates.Signature(id: 1, size: 100, digest: nil, duration: 10, width: 100, height: 100, hashes: [1, 2, 3, 4, 5], created: Date(timeIntervalSince1970: 1))
        var other = base
        other.id = 2
        other.size = 200
        #expect(LocalDuplicates.matches(base, other))
        other.duration = 10.6
        #expect(!LocalDuplicates.matches(base, other))
        other.duration = 10
        other.width = 101
        #expect(!LocalDuplicates.matches(base, other))
        other.width = 100
        other.hashes = [1, 2, 3, 4]
        #expect(!LocalDuplicates.matches(base, other))
        // Matching size but no digest never counts as byte-identical.
        other.hashes = []
        other.size = 100
        #expect(!LocalDuplicates.matches(base, other))
    }
    @Test func keeperPrefersOldestThenLowestID() {
        let old = LocalDuplicates.Signature(id: 3, size: 100, digest: "d", duration: 10, width: 100, height: 100, hashes: [], created: Date(timeIntervalSince1970: 1))
        var newer = old
        newer.id = 1
        newer.created = Date(timeIntervalSince1970: 5)
        var sameAge = old
        sameAge.id = 2
        #expect(LocalDuplicates.groups([newer, sameAge, old]).first?.keepID == 2)
        #expect(LocalDuplicates.groups([newer, sameAge, old]).first?.videoIDs.sorted() == [1, 2, 3])
    }
}
