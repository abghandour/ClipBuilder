import Foundation
import Testing
@testable import Clip_Builder

/// Fixtures travel through the real request/decoding code without a network call.
actor ElevenLabsTransportStub {
    private var responses: [(Int, Data)]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(Int, Data)]) { self.responses = responses }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let fixture = responses.isEmpty ? (500, Data()) : responses.removeFirst()
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: fixture.0, httpVersion: nil, headerFields: nil))
        return (fixture.1, response)
    }

    nonisolated func client(key: String = "fixture-key") -> ElevenLabsClient {
        ElevenLabsClient(apiKey: key, transport: { try await self.send($0) })
    }
}

nonisolated enum ElevenLabsFixtures {
    static let subscription = Data(#"{"tier":"starter","character_count":120,"character_limit":30000,"next_character_count_reset_unix":1796256000}"#.utf8)
    static let voices = Data(#"""
        {"voices":[
          {"voice_id":"ana-id","name":"Ana","category":"cloned","labels":{"gender":"female","language":"en"},
           "verified_languages":[{"language":"en","locale":"en-US","accent":"american"}]},
          {"voice_id":"sam-id","name":"Samantha","category":"premade","labels":{"gender":"male"}},
          {"voice_id":"fred-id","name":"Fred","category":"generated"},
          {"voice_id":"sandy-id","name":"Sandy","category":"professional","labels":{}},
          {"voice_id":"unknown-id","name":"Unlisted","category":"premade","labels":{"gender":"neutral"}}
        ],"has_more":false,"total_count":5}
        """#.utf8)
}

struct ElevenLabsClientTests {
    @Test func subscriptionUsesKeyHeaderAndDecodesCredits() async throws {
        let stub = ElevenLabsTransportStub([(200, ElevenLabsFixtures.subscription)])
        let subscription = try await stub.client().subscription()
        #expect(subscription.tier == "starter")
        #expect(subscription.characterCount == 120)
        #expect(subscription.characterLimit == 30000)
        #expect(subscription.nextCharacterCountResetUnix == 1796256000)
        let requests = await stub.requests
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/user/subscription")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "fixture-key")
        #expect(request.timeoutInterval == 60)
        #expect(request.httpBody == nil)
    }

    @Test func voicesUsesV2AndPageSize() async throws {
        let stub = ElevenLabsTransportStub([(200, ElevenLabsFixtures.voices)])
        let voices = try await stub.client().voices()
        #expect(voices.count == 5)
        let request = try #require(await stub.requests.first)
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v2/voices?page_size=100")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "fixture-key")
        #expect(request.timeoutInterval == 60)
    }

    @Test func speakSendsOnlySpeechSettingsAndReturnsAudioBytes() async throws {
        let audio = Data([0x49, 0x44, 0x33, 0x01])
        let stub = ElevenLabsTransportStub([(200, audio)])
        var settings = ElevenLabsSettings()
        settings.stability = 0.4
        settings.similarity = 0.8
        let result = try await stub.client().speak(text: "Olá", voiceID: "voice-id", model: settings.model, settings: settings)
        #expect(result == audio)
        let request = try #require(await stub.requests.first)
        #expect(request.url?.path == "/v1/text-to-speech/voice-id")
        #expect(request.url?.query == "output_format=mp3_44100_128")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 60)
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "fixture-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "audio/mpeg")
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["text"] as? String == "Olá")
        #expect(object["model_id"] as? String == "eleven_multilingual_v2")
        #expect(object["language_code"] == nil)
        #expect(object["api_key"] == nil)
        let voice = try #require(object["voice_settings"] as? [String: Any])
        #expect(voice["stability"] as? Double == 0.4)
        #expect(voice["similarity_boost"] as? Double == 0.8)
        #expect(voice["use_speaker_boost"] as? Bool == true)
        #expect(voice["concurrency"] == nil)
    }

    @Test func mapsErrorFixturesWithoutLosingQuotaToThe401Case() async throws {
        let fixtures: [(Int, String, ElevenLabsError)] = [
            (401, #"{"detail":{"status":"invalid_api_key","message":"Invalid key"}}"#, .invalidKey),
            (401, #"{"detail":{"status":"quota_exceeded","remaining":4}}"#, .quotaExceeded(remaining: 4)),
            (401, #"{"detail":{"status":"quota_exceeded","message":"Quota exceeded"}}"#, .quotaExceeded(remaining: nil)),
            (422, #"{"detail":{"message":"Voice not found"}}"#, .badRequest("Voice not found")),
            (422, #"{"detail":[{"msg":"Text is required"}]}"#, .badRequest("Text is required")),
            (400, #"{"detail":"Invalid text"}"#, .badRequest("Invalid text")),
            (503, "unavailable", .http(503)),
        ]
        for (status, json, expected) in fixtures {
            let stub = ElevenLabsTransportStub([(status, Data(json.utf8))])
            do {
                _ = try await stub.client().subscription()
                Issue.record("Expected \(expected)")
            } catch {
                #expect(error as? ElevenLabsError == expected)
                #expect(error.localizedDescription == expected.userMessage)
            }
            #expect(await stub.requests.count == 1)
        }
        #expect(ElevenLabsError.invalidKey.userMessage == "Add your ElevenLabs key in Settings > AI")
        #expect(ElevenLabsError.quotaExceeded(remaining: nil).userMessage.hasPrefix("Your ElevenLabs credits for this month are used up"))
    }

    @Test func retries429OnceThenSucceeds() async throws {
        let limited = Data(#"{"detail":{"status":"too_many_concurrent_requests"}}"#.utf8)
        let stub = ElevenLabsTransportStub([(429, limited), (200, ElevenLabsFixtures.subscription)])
        #expect(try await stub.client().subscription().tier == "starter")
        let requests = await stub.requests
        #expect(requests.count == 2)
        #expect(requests.first == requests.last)
    }

    @Test func stopsAfterTheSecond429() async throws {
        let limited = Data(#"{"detail":{"status":"too_many_concurrent_requests"}}"#.utf8)
        let stub = ElevenLabsTransportStub([(429, limited), (429, limited), (200, ElevenLabsFixtures.subscription)])
        do {
            _ = try await stub.client().subscription()
            Issue.record("Expected the retry limit")
        } catch {
            #expect(error as? ElevenLabsError == .tooManyRequests)
        }
        #expect(await stub.requests.count == 2)
    }

    @Test func missingKeyNeverSendsARequest() async throws {
        let stub = ElevenLabsTransportStub([])
        do {
            _ = try await stub.client(key: " \n").subscription()
            Issue.record("Expected a missing-key error")
        } catch {
            #expect(error as? ElevenLabsError == .invalidKey)
        }
        #expect(await stub.requests.isEmpty)
    }

    @Test func settingsRemainBackwardCompatibleAndContainNoKey() throws {
        let old = try JSONDecoder().decode(AIConfig.self, from: Data("{}".utf8))
        #expect(old.elevenLabs == nil)
        #expect(old.preferOnDevice && old.providerCooldownMinutes == 15)
        var config = old
        config.elevenLabs = ElevenLabsSettings()
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AIConfig.self, from: data)
        #expect(decoded.elevenLabs == ElevenLabsSettings())
        let settings = try #require(decoded.elevenLabs)
        #expect(settings.model == "eleven_multilingual_v2")
        #expect(settings.stability == 0.5 && settings.similarity == 0.75 && settings.concurrency == 2)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let speech = try #require(object["eleven_labs"] as? [String: Any])
        #expect(Set(speech.keys) == ["model", "stability", "similarity", "concurrency"])
    }
}
