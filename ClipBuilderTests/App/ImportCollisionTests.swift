import Foundation
import Testing
@testable import Clip_Builder

@Suite("Import collisions")
struct ImportCollisionTests {
    @Test("a file already in the folder, or a same-size namesake, counts as already imported; a different file gets a numbered name")
    func destinations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Input")
        let elsewhere = root.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = folder.appendingPathComponent("a.mp4")
        try Data(repeating: 1, count: 10).write(to: inside)
        #expect(try AppStore.copyDestination(for: inside, folder: folder).existed)
        let sameSize = elsewhere.appendingPathComponent("a.mp4")
        try Data(repeating: 2, count: 10).write(to: sameSize)
        let same = try AppStore.copyDestination(for: sameSize, folder: folder)
        #expect(same.existed && same.url.lastPathComponent == "a.mp4")
        let bigger = elsewhere.appendingPathComponent("a.mp4")
        try Data(repeating: 3, count: 20).write(to: bigger)
        let numbered = try AppStore.copyDestination(for: bigger, folder: folder)
        #expect(!numbered.existed && numbered.url.lastPathComponent == "a 2.mp4")
        #expect(FileManager.default.fileExists(atPath: numbered.url.path))
        let fresh = elsewhere.appendingPathComponent("b.mp4")
        try Data(repeating: 4, count: 5).write(to: fresh)
        let copied = try AppStore.copyDestination(for: fresh, folder: folder)
        #expect(!copied.existed && copied.url.lastPathComponent == "b.mp4")
    }

    @Test("name lists read naturally")
    func names() {
        #expect(AppStore.nameList(["a.mp4"]) == "a.mp4")
        #expect(AppStore.nameList(["a", "b"]) == "a and b")
        #expect(AppStore.nameList(["a", "b", "c"]) == "a, b and c")
        #expect(AppStore.nameList(["1", "2", "3", "4", "5", "6", "7"]) == "1, 2, 3, 4, 5 and 2 more")
    }
}
