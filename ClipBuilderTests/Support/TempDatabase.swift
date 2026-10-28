import Foundation
@testable import Clip_Builder

struct TempDatabase {
    let directory: TempDirectory
    let database: Database
    let path: URL

    /// Opens the database off the caller's actor: creating the schema takes
    /// ~150 ms of SQLite work, and hundreds of main-actor tests doing it
    /// inline serialise into a stall that trips other suites' time limits.
    init() async throws {
        let directory = try TempDirectory(prefix: "ClipBuilderDatabase")
        let path = directory.url.appendingPathComponent("test.db")
        self.directory = directory
        self.path = path
        database = try await Task.detached { try Database(path: path) }.value
    }

    @discardableResult
    func seedVideo(sceneCount: Int = 1) async throws -> Int64 {
        let videoURL = directory.url.appendingPathComponent("fixture.mp4")
        if !FileManager.default.fileExists(atPath: videoURL.path) {
            try Data("fixture".utf8).write(to: videoURL)
        }
        let videoID = try await database.registerVideo(
            hash: UUID().uuidString,
            filename: "fixture.mp4",
            path: videoURL.path,
            duration: Double(max(sceneCount, 1) * 10),
            width: 1920,
            height: 1080,
            wide: true
        )
        var ranges: [(start: Double, end: Double)] = []
        for index in 0..<sceneCount {
            ranges.append((Double(index * 10), Double(index * 10 + 8)))
        }
        _ = try await database.saveAnalysis(
            videoID: videoID,
            runName: "Fixture",
            instructions: "",
            sampleInterval: 1,
            notesJSON: nil,
            tagRanges: ["fixture": ranges],
            moments: [],
            analyzedTags: ["fixture"],
            provider: "test",
            model: "fixture",
            mode: "visual"
        )
        return videoID
    }
}
