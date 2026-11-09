import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

struct ElevenLabsDubSynthesizerTests {
    private nonisolated static let voice = "elevenlabs:fixture-voice"

    private static func synthesizer(_ stub: ElevenLabsTransportStub) -> ElevenLabsDubSynthesizer {
        ElevenLabsDubSynthesizer(settings: { ElevenLabsSettings() }, key: { "fixture-key" },
                                client: { _ in stub.client() })
    }

    private static func fixtureMP3(directory: URL) async throws -> Data {
        let url = directory.appendingPathComponent("fixture.mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try await FFmpeg.run(["-y", "-nostdin", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                              "-ar", "44100", "-c:a", "libmp3lame", "-b:a", "128k", url.path])
        return try Data(contentsOf: url)
    }

    @Test(.enabled(if: FFmpeg.isAvailable, "ffmpeg is required for MP3/CAF conversion"))
    func sharedRoutingCachesOriginalAndFitsWithoutAnotherRequest() async throws {
        let temp = try TempDirectory()
        let directory = temp.url
        let audio = try await Self.fixtureMP3(directory: directory)
        let stub = ElevenLabsTransportStub([(200, audio), (200, audio)])
        let synthesizer = DubSynthesizer(directory: directory, elevenLabs: Self.synthesizer(stub))
        let messages = Mutex<[String]>([])
        let commands = Mutex<[[String]]>([])
        let urls = try await ElevenLabsDubUsage.withLogging(enabled: true,
            log: { message in messages.withLock { $0.append(message) } }) {
            try await FFmpeg.$commandCompleted.withValue({ command in commands.withLock { $0.append(command) } }) {
                let plain = try await synthesizer.synthesize(text: "Olá", voice: Self.voice, rate: 1)
                let cached = try await synthesizer.synthesize(text: "Olá", voice: Self.voice, rate: 1)
                let fast = try await synthesizer.synthesize(text: "Olá", voice: Self.voice, rate: 1.25)
                let other = try await synthesizer.synthesize(text: "Adeus", voice: Self.voice, rate: 1)
                return (plain, cached, fast, other)
            }
        }
        #expect(urls.0 == urls.1 && urls.0 != urls.2 && urls.0 != urls.3)
        #expect(urls.0.lastPathComponent == (try DubSynthesizer.cacheName(language: "elevenlabs",
            voice: DubTake.cacheVoice(Self.voice, settings: ElevenLabsSettings()), rate: 1, text: "Olá")))
        #expect(await stub.requests.count == 2)
        let plainDuration = try DubSynthesizer.fileDuration(of: urls.0)
        let fastDuration = try DubSynthesizer.fileDuration(of: urls.2)
        #expect(abs(fastDuration - plainDuration / 1.25) < 0.06)
        let file = try AVAudioFile(forReading: urls.0)
        #expect(file.fileFormat.sampleRate == 48000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.commonFormat == .pcmFormatFloat32)
        let conversions = commands.withLock { $0 }
        #expect(conversions.count == 3)
        #expect(!conversions[0].contains("-filter:a"))
        #expect(conversions[1].contains("atempo=1.2500"))
        #expect(conversions[1].contains(urls.0.path))
        #expect(messages.withLock { $0 } == ["ElevenLabs request: 3 characters",
            "ElevenLabs request: 5 characters", "ElevenLabs: 3 characters reused · 8 characters requested"])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        // The listing resolves /var to /private/var; compare names, not URLs.
        #expect(Set(files.map(\.lastPathComponent)) == Set([urls.0, urls.2, urls.3].map(\.lastPathComponent)))

        messages.withLock { $0.removeAll() }
        _ = try await ElevenLabsDubUsage.withLogging(enabled: true,
            log: { message in messages.withLock { $0.append(message) } }) {
            try await synthesizer.synthesize(text: "Olá", voice: Self.voice, rate: 1.25)
        }
        #expect(messages.withLock { $0 } == ["ElevenLabs: 0 characters reused · 0 characters requested"])
        #expect(await stub.requests.count == 2)
    }

    @Test(.enabled(if: FFmpeg.isAvailable, "ffmpeg is required for MP3/CAF conversion"))
    func coldFitRetainsOriginalAndModelChangeInvalidatesCache() async throws {
        let temp = try TempDirectory()
        let directory = temp.url
        let audio = try await Self.fixtureMP3(directory: directory)
        let stub = ElevenLabsTransportStub([(200, audio), (200, audio)])
        let settings = Mutex(ElevenLabsSettings())
        let synthesizer = ElevenLabsDubSynthesizer(settings: { settings.withLock { $0 } },
            key: { "fixture-key" }, client: { _ in stub.client() })
        _ = try await synthesizer.synthesize(text: "Hello", voice: Self.voice, rate: 1.2, directory: directory)
        let original = try await synthesizer.synthesize(text: "Hello", voice: Self.voice, rate: 1, directory: directory)
        _ = try await synthesizer.synthesize(text: "Hello", voice: Self.voice, rate: 1.25, directory: directory)
        #expect(await stub.requests.count == 1)
        settings.withLock { $0.model = "eleven_flash_v2_5"; $0.stability = 0.3; $0.similarity = 0.8 }
        let changed = try await synthesizer.synthesize(text: "Hello", voice: Self.voice, rate: 1, directory: directory)
        #expect(changed != original)
        #expect(await stub.requests.count == 2)
        let request = try #require(await stub.requests.last)
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model_id"] as? String == "eleven_flash_v2_5")
        let voiceSettings = try #require(object["voice_settings"] as? [String: Any])
        #expect(voiceSettings["stability"] as? Double == 0.3)
        #expect(voiceSettings["similarity_boost"] as? Double == 0.8)
    }

    @Test(.enabled(if: FFmpeg.isAvailable, "ffmpeg is required for MP3/CAF conversion"))
    func simultaneousCopiesOfOneTextShareTheOriginalRequest() async throws {
        let temp = try TempDirectory()
        let directory = temp.url
        let stub = ElevenLabsTransportStub([(200, try await Self.fixtureMP3(directory: directory))])
        let synthesizer = Self.synthesizer(stub)
        let urls = try await BoundedConcurrency.map([1.0, 1.25, 1.0, 1.2], limit: 4) { _, rate in
            try await synthesizer.synthesize(text: "Hello", voice: Self.voice, rate: rate, directory: directory)
        }
        #expect(urls[0] == urls[2])
        #expect(await stub.requests.count == 1)
        for url in urls { #expect(try DubSynthesizer.fileDuration(of: url) > 0) }
    }

    @Test func invalidInputNeverRequestsSpeech() async throws {
        let temp = try TempDirectory()
        let stub = ElevenLabsTransportStub([])
        let synthesizer = Self.synthesizer(stub)
        let invalid: [(String, String, Double)] = [
            ("Hello", "mac-voice", 1), ("Hello", "elevenlabs:", 1),
            ("", Self.voice, 1), (" \n", Self.voice, 1), ("Hello", Self.voice, 0.99),
            ("Hello", Self.voice, 1.26), ("Hello", Self.voice, .nan), ("Hello", Self.voice, .infinity),
        ]
        for (text, voice, rate) in invalid {
            await #expect(throws: ScriptError.self) {
                try await synthesizer.synthesize(text: text, voice: voice, rate: rate, directory: temp.url)
            }
        }
        #expect(await stub.requests.isEmpty)
    }

    @Test func missingKeyPreservesClientMessageWithoutARequest() async throws {
        let temp = try TempDirectory()
        let stub = ElevenLabsTransportStub([])
        for key: String? in [nil, "", " \n"] {
            let synthesizer = ElevenLabsDubSynthesizer(settings: { ElevenLabsSettings() }, key: { key },
                                                      client: { _ in stub.client() })
            do {
                _ = try await synthesizer.synthesize(text: "Hello", voice: Self.voice, rate: 1, directory: temp.url)
                Issue.record("Expected a missing-key error")
            } catch {
                #expect(error as? ElevenLabsError == .invalidKey)
                #expect(error.localizedDescription == ElevenLabsError.invalidKey.userMessage)
            }
        }
        #expect(await stub.requests.isEmpty)
    }

    @Test func serviceErrorsReachTheJobUnchangedAndStillLogSentCharacters() async throws {
        let temp = try TempDirectory()
        let directory = temp.url
        let fixtures: [(Int, String, ElevenLabsError)] = [
            (401, #"{"detail":{"status":"invalid_api_key"}}"#, .keyRejected(nil)),
            (401, #"{"detail":{"status":"quota_exceeded"}}"#, .quotaExceeded(remaining: nil)),
            (422, #"{"detail":{"message":"Voice not found"}}"#, .badRequest("Voice not found")),
            (503, "unavailable", .http(503)),
        ]
        for (status, json, expected) in fixtures {
            let stub = ElevenLabsTransportStub([(status, Data(json.utf8))])
            let synthesizer = Self.synthesizer(stub)
            let messages = Mutex<[String]>([])
            do {
                _ = try await ElevenLabsDubUsage.withLogging(enabled: true,
                    log: { message in messages.withLock { $0.append(message) } }) {
                    try await synthesizer.synthesize(text: "Hello", voice: Self.voice, rate: 1, directory: directory)
                }
                Issue.record("Expected \(expected)")
            } catch {
                #expect(error as? ElevenLabsError == expected)
                #expect(error.localizedDescription == expected.userMessage)
            }
            #expect(await stub.requests.count == 1)
            #expect(messages.withLock { $0 } == ["ElevenLabs request: 5 characters", "ElevenLabs: 0 characters reused · 5 characters requested"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    @Test func stopBeforeRequestNeverCallsTheTransport() async throws {
        let temp = try TempDirectory()
        let directory = temp.url
        let stub = ElevenLabsTransportStub([])
        let synthesizer = Self.synthesizer(stub)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await synthesizer.synthesize(text: "Hello", voice: Self.voice, rate: 1, directory: directory)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await stub.requests.isEmpty)
    }

    @Test func stopAfterResponseDoesNotPublishAudio() async throws {
        let temp = try TempDirectory()
        let directory = temp.url
        let requests = Mutex(0)
        let client = ElevenLabsClient(apiKey: "fixture-key", transport: { request in
            requests.withLock { $0 += 1 }
            withUnsafeCurrentTask { $0?.cancel() }
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url,
                statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data("unused audio".utf8), response)
        })
        let synthesizer = ElevenLabsDubSynthesizer(settings: { ElevenLabsSettings() }, key: { "fixture-key" },
                                                  client: { _ in client })
        let task = Task {
            try await synthesizer.synthesize(text: "Hello", voice: Self.voice, rate: 1, directory: directory)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(requests.withLock { $0 } == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}

extension ElevenLabsDubSynthesizerTests {
    @Test(.enabled(if: FFmpeg.isAvailable))
    func flashDraftUsesSameVoiceAndSeparateModelCache() async throws {
        let temp = try TempDirectory()
        let bytes = try await Self.fixtureMP3(directory: temp.url)
        let stub = ElevenLabsTransportStub([(200, bytes), (200, bytes)])
        let synth = Self.synthesizer(stub)
        let draft = try await synth.synthesize(text: "Hello", voice: Self.voice, rate: 1,
            directory: temp.url, model: "eleven_flash_v2_5")
        let again = try await synth.synthesize(text: "Hello", voice: Self.voice, rate: 1,
            directory: temp.url, model: "eleven_flash_v2_5")
        let final = try await synth.synthesize(text: "Hello", voice: Self.voice, rate: 1, directory: temp.url)
        #expect(draft == again && draft != final)
        let requests = await stub.requests
        #expect(requests.count == 2)
        var models: [String] = []
        for request in requests {
            #expect(request.url?.path.hasSuffix("/fixture-voice") == true)
            let body = try #require(request.httpBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            models.append(try #require(json["model_id"] as? String))
        }
        #expect(models == ["eleven_flash_v2_5", "eleven_multilingual_v2"])
    }
}
