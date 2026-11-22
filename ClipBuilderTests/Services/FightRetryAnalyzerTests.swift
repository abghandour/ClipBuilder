import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@Suite("Fight retry Analyzer", .serialized)
struct FightRetryAnalyzerTests {
    private func service(answer: String, requests: FightRetryTestLog) -> AIService {
        var config = AIConfig()
        config.providers["claude"] = AIProviderSettings(bin: "/usr/bin/true", model: "fixture")
        config.tasks["analysis"] = "claude"
        config.tasks["fight_lessons"] = "claude"
        config.taskModels["analysis"] = "fixture"
        config.taskModels["fight_lessons"] = "fixture"
        return AIService(config: config) { _, _, stdin, _, _, _ in
            let object = try JSONSerialization.jsonObject(with: stdin ?? Data()) as? [String: Any]
            let message = object?["message"] as? [String: Any]
            let content = message?["content"] as? [[String: Any]]
            let prompt = content?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
            requests.append(prompt)
            let response: [String: Any] = ["type": "assistant", "message": [
                "content": [["type": "text", "text": answer]],
            ]]
            return ProcessResult(stdout: try JSONSerialization.data(withJSONObject: response), stderr: Data(), exitCode: 0)
        }
    }

    @Test(.enabled(if: FixtureVideo.integrationsAvailable, "Install ffmpeg and ffprobe to run."))
    func injectedScoringResponseCannotOverwriteCorrection() async throws {
        let temp = try await TempDatabase()
        let source = try await FixtureVideo.make(in: temp.directory.url, wide: true, silent: true)
        let videoID = try await temp.database.registerVideo(hash: UUID().uuidString, filename: source.lastPathComponent,
            path: source.path, duration: 3, width: 1920, height: 1080, wide: true)
        try await temp.database.setVideoType(id: videoID, type: "fight")
        let video = try #require(try await temp.database.video(id: videoID))
        let original = FightEventRecord(id: 0, videoID: videoID, time: 1, fighterKey: "", action: "takedown_attempt",
            points: 4, endTime: 2, outcome: "completed", scoringVersion: 3)
        try await temp.database.replaceFightEventRecords(videoID: videoID, events: [original])
        let saved = try #require(try await temp.database.fetchFightEvents(videoID: videoID).first)
        var corrected = saved
        corrected.outcome = "defended"
        _ = try await temp.database.saveFightCorrection(.init(event: saved, kind: .edit, replacement: corrected))
        let requests = FightRetryTestLog()
        let ai = service(answer: #"{"events":[{"at_time":1,"fighter":"unknown","action":"takedown_attempt","end_time":2,"outcome":"completed"}]}"#, requests: requests)
        let count = try await Analyzer(ai: ai).scoreFightAction(video: video, profile: BrandProfile(name: "Retry fixture"),
            database: temp.database, provider: "claude", model: "fixture", retryScope: .wholeFight, log: { _ in })
        let after = try await temp.database.fetchFightEvents(videoID: videoID)
        #expect(count == 1 && after.count == 1)
        #expect(after.first?.outcome == "defended" && after.first?.points == 0)
        #expect(after.first?.generation != saved.generation)
        #expect(requests.lines.count == 1)
        #expect(requests.lines.first?.contains("REVIEWED BY A PERSON") == true)
        #expect(requests.lines.first?.contains("outcome defended") == true)
        let pass = try #require(try await temp.database.fetchAnalysisPasses().last)
        #expect(pass.status == .completed && pass.note?.contains("Whole-fight retry") == true)
    }

    @Test func learningThresholdFailureAndSuccessKeepScoredEvents() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        for index in 0..<4 {
            let event = FightEventRecord(id: 0, videoID: videoID, time: Double(index * 2), fighterKey: "a", action: "strike", points: 1)
            _ = try await temp.database.saveFightCorrection(.init(event: event, kind: .add))
        }
        let requests = FightRetryTestLog()
        let ai = service(answer: #"{"lessons":["valid",42]}"#, requests: requests)
        #expect(await FightScoringLearning.update(database: temp.database, ai: ai, log: { _ in }) == nil)
        #expect(requests.lines.isEmpty)
        let fifth = FightEventRecord(id: 0, videoID: videoID, time: 9, fighterKey: "a", action: "strike", points: 1)
        _ = try await temp.database.saveFightCorrection(.init(event: fifth, kind: .add))
        let before = try await temp.database.fetchFightEvents(videoID: videoID)
        let logs = FightRetryTestLog()
        #expect(await FightScoringLearning.update(database: temp.database, ai: ai, log: { line in logs.append(line) }) == nil)
        #expect(requests.lines.count == 1)
        #expect(logs.lines.contains { $0.contains("retry result is kept") })
        #expect(try await temp.database.fetchFightEvents(videoID: videoID) == before)
        #expect(try await temp.database.fightLearningSnapshot().corrections.count == 5)
        let good = service(answer: #"{"lessons":["Trace the initiating limb."]}"#, requests: requests)
        #expect(await FightScoringLearning.update(database: temp.database, ai: good, log: { _ in }) == 1)
        #expect(try await temp.database.fightLearningSnapshot().corrections.isEmpty)
        #expect(try await temp.database.fetchFightEvents(videoID: videoID) == before)
    }
}

nonisolated private final class FightRetryTestLog: Sendable {
    private let storage = Mutex<[String]>([])
    var lines: [String] { storage.withLock { $0 } }
    func append(_ line: String) { storage.withLock { $0.append(line) } }
}
