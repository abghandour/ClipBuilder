import Foundation
import Testing
@testable import Clip_Builder

/// A copy of footage added again is linked to the row without a file here.
struct SourceRelinkTests {
    private func row(_ id: Int64, _ filename: String, duration: Double, path: String?, hash: String? = nil) -> VideoRecord {
        var video = Fixtures.video(id: id)
        video.hash = hash ?? "hash-\(id)"
        video.filename = filename
        video.path = path
        video.duration = duration
        return video
    }

    @Test func aMissingRowIsFoundByNameAndDurationNotHash() {
        let rows = [row(1, "Johnny Walker og Interview.mp4", duration: 689.19, path: ""),
                    row(2, "Johnny Walker og Interview.mp4", duration: 258.0, path: ""),
                    row(3, "Other.mp4", duration: 689.19, path: "")]
        let isLocal: (String?) -> Bool = { $0 == "/here/local.mp4" }
        let target = SourceRelink.target(filename: "johnny walker og interview.MOV", duration: 688.7,
                                         path: "/here/Johnny.mov", in: rows, isLocal: isLocal)
        #expect(target?.id == 1, "case and extension aside, same name and about the same length")
        #expect(SourceRelink.target(filename: "Johnny Walker og Interview.mp4", duration: 600, path: "/x", in: rows, isLocal: isLocal) == nil)
        #expect(SourceRelink.target(filename: "Johnny Walker og Interview.mp4", duration: 0, path: "/x", in: rows, isLocal: isLocal) == nil)
    }

    @Test func aRowWithAFileOnThisMacIsNeverTakenOver() {
        let local = row(1, "Clip.mp4", duration: 10, path: "/here/local.mp4")
        let isLocal: (String?) -> Bool = { $0 == "/here/local.mp4" }
        #expect(SourceRelink.target(filename: "Clip.mp4", duration: 10, path: "/here/copy.mp4", in: [local], isLocal: isLocal) == nil)
        #expect(SourceRelink.target(filename: "Clip.mp4", duration: 10, path: "/here/local.mp4", in: [local], isLocal: isLocal)?.id == 1,
                "a linked file probed again stays with its row")
        let ghost = row(2, "Clip.mp4", duration: 0, path: "/here/ghost.mp4")
        #expect(SourceRelink.target(filename: "Clip.mp4", duration: 10, path: "/here/ghost.mp4", in: [ghost], isLocal: isLocal) == nil,
                "a zero-duration row at the path registers afresh")
    }

    @Test func duplicatesPairEachMissingRowWithItsLocalCopy() {
        let rows = [row(1, "Interview.mp4", duration: 100, path: ""),
                    row(2, "Interview.mov", duration: 100.4, path: "/here/Interview.mov"),
                    row(3, "Solo.mp4", duration: 50, path: "")]
        let pairs = SourceRelink.duplicates(in: rows) { $0 == "/here/Interview.mov" }
        #expect(pairs.count == 1 && pairs.first?.local.id == 2 && pairs.first?.missing.id == 1)
    }
}
