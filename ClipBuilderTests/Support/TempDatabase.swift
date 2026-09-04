import Foundation
@testable import Clip_Builder

struct TempDatabase {
    let directory: TempDirectory
    let database: Database
    let path: URL

    init() throws {
        directory = try TempDirectory(prefix: "ClipBuilderDatabase")
        path = directory.url.appendingPathComponent("test.db")
        database = try Database(path: path)
    }

    @discardableResult
    func seedVideo(sceneCount: Int = 1) async throws -> Int64 {
        let videoID = try await database.registerVideo(
            hash: UUID().uuidString,
            filename: "fixture.mp4",
            path: directory.url.appendingPathComponent("fixture.mp4").path,
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
