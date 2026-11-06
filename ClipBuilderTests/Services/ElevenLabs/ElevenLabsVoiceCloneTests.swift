import Foundation
import Testing
@testable import Clip_Builder

struct ElevenLabsVoiceCloneTests {
    @Test func uploadsMultipartSamplesAndGenderLabels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.wav")
        let second = directory.appendingPathComponent("second.wav")
        let audio = Data([0, 1, 255, 13, 10, 42])
        try audio.write(to: first)
        try Data("second sample".utf8).write(to: second)
        let stub = ElevenLabsTransportStub([(200, Data(#"{"voice_id":"alice-clone","requires_verification":false}"#.utf8))])
        let id = try await stub.client().addVoice(name: "Alice (Clip Builder)", files: [first, second],
            labels: ["gender": "female", "source": "clip-builder"], removeBackgroundNoise: true)
        #expect(id == "alice-clone")
        let requests = await stub.requests
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/voices/add")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "fixture-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let data = try #require(request.httpBody)
        #expect(data.range(of: audio) != nil)
        let body = String(decoding: data, as: UTF8.self)
        #expect(body.hasPrefix("--\(boundary)\r\n"))
        #expect(body.hasSuffix("--\(boundary)--\r\n"))
        #expect(body.contains("name=\"name\"\r\n\r\nAlice (Clip Builder)\r\n"))
        #expect(body.contains("name=\"remove_background_noise\"\r\n\r\ntrue\r\n"))
        #expect(body.contains("name=\"files\"; filename=\"first.wav\""))
        #expect(body.contains("name=\"files\"; filename=\"second.wav\""))
        let labelPart = try #require(body.components(separatedBy: "--\(boundary)").first {
            $0.contains("name=\"labels\"")
        })
        let json = try #require(labelPart.components(separatedBy: "\r\n\r\n").last)
        let labels = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        #expect(labels == ["gender": "female", "source": "clip-builder"])
    }

    @Test func deleteEscapesOnePathComponentAndAcceptsAnEmptyResponse() async throws {
        let stub = ElevenLabsTransportStub([(204, Data())])
        try await stub.client().deleteVoice(id: "voice/with ?#%")
        let requests = await stub.requests
        let request = try #require(requests.first)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(request.httpMethod == "DELETE")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "fixture-key")
        #expect(components.percentEncodedPath == "/v1/voices/voice%2Fwith%20%3F%23%25")
        #expect(components.query == nil && components.fragment == nil)
    }

    @Test func planLimitMessageReachesTheUser() async throws {
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data("sample".utf8).write(to: sample)
        defer { try? FileManager.default.removeItem(at: sample) }
        let stub = ElevenLabsTransportStub([(400, Data(#"{"detail":{"status":"voice_limit_reached","message":"You have reached your custom voice limit."}}"#.utf8))])
        do {
            _ = try await stub.client().addVoice(name: "Alice", files: [sample], labels: [:], removeBackgroundNoise: false)
            Issue.record("Expected the plan-limit error")
        } catch {
            #expect(error as? ElevenLabsError == .badRequest("You have reached your custom voice limit."))
            #expect(error.localizedDescription.contains("You have reached your custom voice limit."))
        }
        let requests = await stub.requests
        let body = String(decoding: try #require(requests.first?.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"remove_background_noise\"\r\n\r\nfalse\r\n"))
    }

    @Test func emptyFilesAndVoiceIDsNeverReachTheTransport() async throws {
        let stub = ElevenLabsTransportStub([])
        await #expect(throws: ElevenLabsError.self) {
            _ = try await stub.client().addVoice(name: "Alice", files: [], labels: [:])
        }
        await #expect(throws: ElevenLabsError.self) { try await stub.client().deleteVoice(id: "") }
        #expect(await stub.requests.isEmpty)
    }

    @Test func forbiddenVoicePermissionKeepsTheServerMessage() async throws {
        let stub = ElevenLabsTransportStub([(403, Data(#"{"detail":{"message":"Your plan does not allow instant voice cloning."}}"#.utf8))])
        do {
            try await stub.client().deleteVoice(id: "clone")
            Issue.record("Expected the permission error")
        } catch {
            #expect(error.localizedDescription.contains("Your plan does not allow instant voice cloning."))
        }
    }

    @Test func cloneMappingsDecodeOldProfilesAndRoundTrip() throws {
        var editing = try JSONDecoder().decode(ProfileEditingDefaults.self, from: Data("{}".utf8))
        #expect(editing.clonedVoices == nil)
        editing.clonedVoices = ["alice": "voice-id"]
        editing.dubVoices = ["alice": "elevenlabs:voice-id"]
        let restored = try JSONDecoder().decode(ProfileEditingDefaults.self, from: JSONEncoder().encode(editing))
        #expect(restored == editing)
    }
}
