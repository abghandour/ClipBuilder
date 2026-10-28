import Foundation
import Testing
@testable import Clip_Builder

@Suite("Analysis request storage")
struct AnalysisRequestStorageTests {
    @Test func successfulNonActiveRunMatchesButFailedCancelledAndEmptyLegacyDoNot() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let request = AnalysisRequestTests.request()
        let id = try await temp.database.saveAnalysis(videoID: videoID, runName: "Matching older batch", instructions: "", sampleInterval: nil,
            notesJSON: nil, tagRanges: [:], moments: [], analyzedTags: [], provider: nil, model: nil, mode: "visual", request: request)
        let otherID = try await temp.database.saveAnalysis(videoID: videoID, runName: "Pinned different batch", instructions: "different", sampleInterval: nil,
            notesJSON: nil, tagRanges: ["tag": [(0, 3)]], moments: [], analyzedTags: [], provider: nil, model: nil, mode: "visual")
        var runs = try await temp.database.fetchAnalysisRuns()
        let other = try #require(runs.first { $0.id == otherID })
        try await temp.database.setActiveRunKey(videoID: videoID, runKey: other.runKey)
        var passes = try await temp.database.fetchAnalysisPasses()
        let duplicate = try #require(AnalysisDuplicates.duplicate(videoID: videoID, request: request, runs: runs, passes: passes))
        #expect(duplicate.id == id)
        #expect(duplicate.requestJSON == request.json)
        #expect(duplicate.requestHash == request.fingerprint)
        #expect(try await temp.database.activeAnalysisRun(videoID: videoID).run?.id == otherID)
        for status in [AnalysisPassRecord.Status.failed, .cancelled] {
            passes = passes.map { row in var row = row; if row.runKey == duplicate.runKey && row.pass == .scenes { row.status = status }; return row }
            #expect(AnalysisDuplicates.duplicate(videoID: videoID, request: request, runs: runs, passes: passes) == nil)
        }
        passes.removeAll { $0.runKey == duplicate.runKey && $0.pass == .scenes }
        #expect(AnalysisDuplicates.duplicate(videoID: videoID, request: request, runs: runs, passes: passes) == nil)
        runs = runs.map { row in var row = row; if row.id == id { row.sceneCount = 1 }; return row }
        #expect(AnalysisDuplicates.duplicate(videoID: videoID, request: request, runs: runs, passes: passes)?.id == id)
    }

    @Test func migrationAddsNullableRequestColumnsAndSyncIncludesThem() async throws {
        let temp = try await TempDatabase()
        _ = try await temp.seedVideo()
        let raw = try SQLiteConnection(path: temp.path.path)
        // Simulate the previous schema after dropping the new columns.
        try raw.execute("ALTER TABLE analysis_runs DROP COLUMN request_hash")
        try raw.execute("ALTER TABLE analysis_runs DROP COLUMN request_json")
        try raw.execute("PRAGMA user_version = 33")
        let reopened = try Database(path: temp.path)
        let columns = try raw.columnNames(of: "analysis_runs")
        #expect(columns.contains("request_hash") && columns.contains("request_json"))
        #expect(try await reopened.fetchAnalysisRuns().allSatisfy { $0.requestJSON == nil && $0.requestHash == nil })
        let table = try #require(SyncTable.all.first { $0.name == "analysis_runs" })
        #expect(table.columns.contains("request_hash") && table.columns.contains("request_json"))
        #expect(SyncEngine.understoodSchemaVersion == 7)
    }
}
