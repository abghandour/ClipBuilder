import Foundation
import Testing
@testable import Clip_Builder

struct LipSyncTests {
    @Test func theRequestNamesBothAssetsAndSyncsOnlyTheSpeaker() throws {
        let body = try JSONEncoder().encode(LipSync.request(videoAsset: "v1", audioAsset: "a1", model: .sync3))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "sync-3")
        let input = try #require(json["input"] as? [[String: String]])
        #expect(input == [["type": "video", "assetId": "v1"], ["type": "audio", "assetId": "a1"]])
        let options = try #require(json["options"] as? [String: Any])
        #expect(options["sync_mode"] as? String == "cut_off")
        #expect((options["active_speaker_detection"] as? [String: Bool]) == ["auto_detect": true])
    }

    @Test func aGenerationReadsAsWaitingDoneUnchangedOrFailed() {
        func outcome(_ status: String, url: String? = nil, error: String? = nil, code: String? = nil) -> LipSync.Outcome {
            LipSync.outcome(.init(id: "g", status: status, outputUrl: url, error: error, errorCode: code))
        }
        #expect(outcome("PENDING") == .waiting && outcome("PROCESSING") == .waiting)
        #expect(outcome("COMPLETED", url: "https://cdn.sync.so/out.mp4") == .done(URL(string: "https://cdn.sync.so/out.mp4")!))
        // Finished without a file, or with one that is not a web address, is not a result.
        #expect(outcome("COMPLETED") == .failed("Sync Labs finished without a video to download."))
        #expect(outcome("COMPLETED", url: "file:///etc/passwd") == .failed("Sync Labs finished without a video to download."))
        #expect(outcome("NO_OP", code: "generation_lipsync_skipped_no_face") == .unchanged("generation_lipsync_skipped_no_face"))
        #expect(outcome("REJECTED", error: "Video too long") == .failed("Video too long"))
        #expect(outcome("FAILED") == .failed("Sync Labs could not finish the video."))
    }

    @Test func theErrorBodyGivesTheServersWordsWhetherOneOrSeveral() throws {
        let one = try JSONDecoder().decode(LipSync.Failure.self, from: Data(#"{"statusCode":402,"message":"No active plan","suggestion":"Subscribe first.","errorCode":"x"}"#.utf8))
        #expect(one.text == "No active plan Subscribe first.")
        let many = try JSONDecoder().decode(LipSync.Failure.self, from: Data(#"{"message":["model is required","input is required"]}"#.utf8))
        #expect(many.text == "model is required input is required")
        let code = try JSONDecoder().decode(LipSync.Failure.self, from: Data(#"{"errorCode":"concurrency_limit_reached"}"#.utf8))
        #expect(code.text == "concurrency_limit_reached")
    }

    @Test func httpStatusesBecomeTheErrorTheUserCanActOn() {
        let body = Data(#"{"message":"nope"}"#.utf8)
        #expect(SyncLabsClient.error(status: 401, body: body) == .keyRejected("nope"))
        #expect(SyncLabsClient.error(status: 402, body: body) == .billing("nope"))
        #expect(SyncLabsClient.error(status: 429, body: body) == .tooManyRequests)
        #expect(SyncLabsClient.error(status: 422, body: body) == .rejected("nope"))
        #expect(SyncLabsClient.error(status: 503, body: Data()) == .http(503, nil))
    }

    @Test func costAndLengthReadPlainly() {
        #expect(abs(LipSync.estimate(seconds: 60, model: .standard) - 3) < 0.0001)
        #expect(LipSync.estimateLabel(seconds: 38, model: .standard) == "about $1.90")
        #expect(LipSync.rateLabel(.standard) == "about $3 a minute")
        #expect(LipSync.rateLabel(.pro) == "about $4.98 a minute")
        #expect(LipSync.length(45) == "45 seconds" && LipSync.length(60) == "1 minute" && LipSync.length(150) == "2.5 minutes")
        #expect(LipSync.model(nil) == .standard && LipSync.model("nonsense") == .standard && LipSync.model("sync-3") == .sync3)
        #expect(LipSync.Account(plan: .init(name: "Creator"), limits: .init(maxOutputDurationSeconds: 300, maxFileSizeBytes: nil)).summary
                == "Creator plan, videos up to 5 minutes")
    }

    @Test func theSyncedPictureKeepsTheReelsOwnAudio() {
        let mux = LipSync.muxArguments(synced: "/s.mp4", original: "/r.mp4", output: "/o.mp4")
        #expect(mux == ["-y", "-i", "/s.mp4", "-i", "/r.mp4", "-map", "0:v:0", "-map", "1:a:0", "-c", "copy",
                        "-movflags", "+faststart", "/o.mp4"])
        #expect(LipSync.sameLength(30.2, as: 30) && !LipSync.sameLength(31, as: 30) && !LipSync.sameLength(0, as: 0))
    }

    @Test func settingsWithoutLipSyncStillDecodeAndTheOptionNeedsADub() throws {
        let old = try JSONDecoder().decode(AIConfig.self, from: Data(#"{"tasks":{}}"#.utf8))
        #expect(old.lipSync == nil)
        var mini = MiniWizardSettings()
        mini.lipSync = true
        let round = try JSONDecoder().decode(MiniWizardSettings.self, from: JSONEncoder().encode(mini))
        #expect(round.lipSync)
        #expect(try JSONDecoder().decode(MiniWizardSettings.self, from: JSONEncoder().encode(MiniWizardSettings())).lipSync == false)
        // Without a dub there is nothing to sync to: the option is not passed on.
        mini.dub = false
        #expect(mini.step2Options(base: WizardStep2Options()).lipSync == nil)
        mini.dub = true
        #expect(mini.step2Options(base: WizardStep2Options()).lipSync == true)
        var options = WizardOptions()
        options.lipSync = true
        #expect(try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(options)).lipSync == true)
        #expect(try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(WizardOptions())).lipSync == nil)
    }
}

/// The pass, with the server and ffmpeg played by closures.
struct LipSyncServiceTests {
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private var polls = 0
        var final = #"{"id":"g1","status":"COMPLETED","outputUrl":"https://cdn.sync.so/out.mp4"}"#
        var limit = 300.0

        func note(_ line: String) { lock.withLock { log.append(line) } }
        var lines: [String] { lock.withLock { log } }

        func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            note("\(request.httpMethod ?? "") \(path) key=\(request.value(forHTTPHeaderField: "x-api-key") ?? "-")")
            let body: String
            switch (request.httpMethod, path) {
            case ("GET", "/v2/account"): body = #"{"plan":{"name":"Creator"},"limits":{"maxOutputDurationSeconds":\#(limit)}}"#
            case ("POST", "/v2/assets/upload"): body = #"{"uploadUrl":"https://upload.sync.so/put/1","url":"https://assets.sync.so/1","expiresIn":900}"#
            case ("POST", "/v2/assets"):
                let type = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["type"] as? String
                body = #"{"id":"\#(type == "VIDEO" ? "vid" : "aud")"}"#
            case ("POST", "/v2/generate"):
                note("idempotency=\(request.value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty == false)")
                note("generate \(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")")
                body = #"{"id":"g1","status":"PENDING"}"#
            case ("GET", "/v2/generate/g1"):
                let count = lock.withLock { polls += 1; return polls }
                body = count < 2 ? #"{"id":"g1","status":"PROCESSING"}"# : final
            default: body = "{}"
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func service(_ server: Server, lengths: [String: Double]) -> LipSyncService {
        var service = LipSyncService()
        service.key = { "sk-test" }
        service.client = { key in
            var client = SyncLabsClient(apiKey: key)
            client.transport = { server.answer($0) }
            client.uploader = { request, file in
                server.note("PUT \(file.lastPathComponent) type=\(request.value(forHTTPHeaderField: "Content-Type") ?? "") key=\(request.value(forHTTPHeaderField: "x-api-key") ?? "-")")
                return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            }
            client.downloader = { source, destination in
                server.note("download \(source.absoluteString)")
                try Data("synced".utf8).write(to: destination)
            }
            return client
        }
        service.duration = { lengths[$0.lastPathComponent] ?? 0 }
        service.pictureDuration = { lengths[$0.lastPathComponent] ?? 0 }
        service.ffmpeg = { arguments in
            // Stands in for ffmpeg: writes the output it was asked for.
            let output = URL(fileURLWithPath: arguments.last!)
            try Data((output.lastPathComponent == "muxed.mp4" ? "muxed" : "audio").utf8).write(to: output)
        }
        service.pollSeconds = 0.01
        return service
    }

    private func reel() throws -> (folder: URL, reel: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lipsync-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reel = folder.appendingPathComponent("Alice interview final.mp4")
        try Data("original".utf8).write(to: reel)
        return (folder, reel)
    }

    @Test func aPassUploadsWaitsDownloadsAndSwapsTheReel() async throws {
        let (folder, reel) = try reel()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = Server()
        let result = try await service(server, lengths: ["Alice interview final.mp4": 30, "synced.mp4": 30.1, "muxed.mp4": 30.1])
            .sync(reel: reel, model: .standard, scratch: folder)
        #expect(result == .synced)
        #expect(try String(contentsOf: reel, encoding: .utf8) == "muxed")
        let lines = server.lines
        // The presigned upload carries no API key; every API call does.
        #expect(lines.contains("PUT Alice interview final.mp4 type=video/mp4 key=-"))
        #expect(lines.contains("PUT reel.wav type=audio/wav key=-"))
        #expect(lines.contains("GET /v2/account key=sk-test"))
        #expect(lines.contains("idempotency=true"))
        #expect(lines.contains("download https://cdn.sync.so/out.mp4"))
        let generate = try #require(lines.first { $0.hasPrefix("generate ") })
        #expect(generate.contains(#""assetId":"vid""#) && generate.contains(#""assetId":"aud""#) && generate.contains("lipsync-2"))
        // Nothing sent names the reel.
        #expect(!lines.filter { !$0.hasPrefix("PUT ") }.contains { $0.contains("Alice") })
        // The scratch folder is left clean.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Alice interview final.mp4"])
    }

    @Test func aReelLongerThanThePlanAllowsIsNeverUploaded() async throws {
        let (folder, reel) = try reel()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = Server()
        server.limit = 60
        await #expect(throws: SyncLabsError.tooLong(seconds: 95, limit: 60)) {
            try await service(server, lengths: ["Alice interview final.mp4": 95]).sync(reel: reel, model: .standard, scratch: folder)
        }
        #expect(!server.lines.contains { $0.hasPrefix("PUT ") || $0.contains("/v2/generate") })
        #expect(try String(contentsOf: reel, encoding: .utf8) == "original")
    }

    @Test func aFailedOrMismatchedResultLeavesTheReelAlone() async throws {
        let (folder, reel) = try reel()
        defer { try? FileManager.default.removeItem(at: folder) }
        let failed = Server()
        failed.final = #"{"id":"g1","status":"FAILED","error":"No face detected"}"#
        await #expect(throws: SyncLabsError.self) {
            try await service(failed, lengths: ["Alice interview final.mp4": 30]).sync(reel: reel, model: .standard, scratch: folder)
        }
        // A shorter picture is not this reel, even though the reel's audio makes the joined file full length.
        await #expect(throws: SyncLabsError.self) {
            try await service(Server(), lengths: ["Alice interview final.mp4": 30, "synced.mp4": 12, "muxed.mp4": 30]).sync(reel: reel, model: .standard, scratch: folder)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Alice interview final.mp4"])
        let unchanged = Server()
        unchanged.final = #"{"id":"g1","status":"NO_OP","errorCode":"generation_lipsync_skipped_no_face"}"#
        let result = try await service(unchanged, lengths: ["Alice interview final.mp4": 30]).sync(reel: reel, model: .standard, scratch: folder)
        #expect(result == .unchanged("generation_lipsync_skipped_no_face"))
        #expect(try String(contentsOf: reel, encoding: .utf8) == "original")
    }

    @Test func withoutAKeyNothingIsSent() async throws {
        let (folder, reel) = try reel()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = Server()
        var service = service(server, lengths: ["Alice interview final.mp4": 30])
        service.key = { nil }
        await #expect(throws: SyncLabsError.missingKey) {
            try await service.sync(reel: reel, model: .standard, scratch: folder)
        }
        #expect(server.lines.isEmpty)
    }
}
