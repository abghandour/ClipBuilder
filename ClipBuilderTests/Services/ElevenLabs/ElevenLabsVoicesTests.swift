import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

struct ElevenLabsVoicesTests {
    @Test func parsesAccountVoicesAndStampsEveryVoiceWithTheRequestedLanguage() async throws {
        let stub = ElevenLabsTransportStub([(200, ElevenLabsFixtures.voices)])
        let account = try await stub.client().voices()
        let ana = try #require(account.first { $0.voiceID == "ana-id" })
        #expect(ana.category == "cloned")
        #expect(ana.labels?["language"] == "en")
        #expect(ana.verifiedLanguages?.first?.locale == "en-US")
        for language in ["pt-BR", "ja", "uk"] {
            let voices = ElevenLabsVoices.voices(from: account, language: language)
            #expect(voices.count == account.count)
            #expect(voices.allSatisfy { $0.language == language && $0.quality == 3 && $0.qualityLabel == "ElevenLabs" })
            #expect(voices.first { $0.identifier == "elevenlabs:ana-id" }?.name == "Ana (cloned)")
            #expect(voices.first { $0.identifier == "elevenlabs:sandy-id" }?.name == "Sandy (cloned)")
            #expect(voices.first { $0.identifier == "elevenlabs:fred-id" }?.name == "Fred")
        }
    }

    @Test func appClonesDropTheUploadSuffixOnlyWhenCloned() {
        let voices = ElevenLabsVoices.voices(from: [
            ElevenLabsVoice(voiceID: "alice", name: "Alice Pereira (Clip Builder)", category: "cloned"),
            ElevenLabsVoice(voiceID: "stock", name: "Stock (Clip Builder)", category: "premade"),
        ], language: "en-US")
        #expect(voices.first { $0.identifier == "elevenlabs:alice" }?.name == "Alice Pereira (cloned)")
        #expect(voices.first { $0.identifier == "elevenlabs:stock" }?.name == "Stock (Clip Builder)")
    }

    @Test func labelGenderWinsThenFallsBackToTheKnownVoiceName() async throws {
        let stub = ElevenLabsTransportStub([(200, ElevenLabsFixtures.voices)])
        let voices = ElevenLabsVoices.voices(from: try await stub.client().voices(), language: "fr")
        #expect(voices.first { $0.identifier == "elevenlabs:ana-id" }?.gender == .female)
        #expect(voices.first { $0.identifier == "elevenlabs:sam-id" }?.gender == .male)
        #expect(voices.first { $0.identifier == "elevenlabs:fred-id" }?.gender == .male)
        #expect(voices.first { $0.identifier == "elevenlabs:sandy-id" }?.gender == .female)
        #expect(voices.first { $0.identifier == "elevenlabs:unknown-id" }?.gender == .unknown)
    }

    @Test func identifiersRoundTripAndDoNotCaptureAppleVoices() {
        let id = "aB01234_xyz"
        let identifier = ElevenLabsVoices.identifierPrefix + id
        #expect(ElevenLabsVoices.isElevenLabs(identifier))
        #expect(ElevenLabsVoices.voiceID(identifier) == id)
        #expect(!ElevenLabsVoices.isElevenLabs("com.apple.siri.natural.Nando"))
        #expect(ElevenLabsVoices.voiceID("com.apple.siri.natural.Nando") == nil)
        #expect(ElevenLabsVoices.voiceID("elevenlabs:") == nil)
        #expect(ElevenLabsVoices.voiceID("other:elevenlabs:voice") == nil)
    }

    @Test func cacheSharesOneFetchUntilExplicitlyRefreshed() async throws {
        let stub = ElevenLabsTransportStub([(200, ElevenLabsFixtures.voices), (200, Data(#"{"voices":[]}"#.utf8))])
        let cache = ElevenLabsVoiceCache(key: { "fixture-key" }, client: { stub.client(key: $0) })
        async let first = cache.voices()
        async let second = cache.voices()
        let (a, b) = try await (first, second)
        #expect(a == b && a.count == 5)
        #expect(try await cache.voices() == a)
        #expect(await stub.requests.count == 1)
        #expect(try await cache.refresh().isEmpty)
        #expect(try await cache.voices().isEmpty)
        #expect(await stub.requests.count == 2)
    }

    @Test func cacheKeepsErrorsUntilRefreshAndNeverFetchesWithoutAKey() async throws {
        let stub = ElevenLabsTransportStub([(401, Data(#"{"detail":{"status":"invalid_api_key"}}"#.utf8)),
                                           (200, ElevenLabsFixtures.voices)])
        let key = Mutex<String?>(nil)
        let cache = ElevenLabsVoiceCache(key: { key.withLock { $0 } }, client: { stub.client(key: $0) })
        do {
            _ = try await cache.voices()
            Issue.record("Expected missing key")
        } catch { #expect(error as? ElevenLabsError == .invalidKey) }
        #expect(await stub.requests.isEmpty)
        key.withLock { $0 = "key" }
        for _ in 0..<2 {
            do {
                _ = try await cache.voices()
                Issue.record("Expected a rejected key")
            } catch { #expect(error as? ElevenLabsError == .keyRejected(nil)) }
        }
        #expect(await stub.requests.count == 1)
        #expect(try await cache.refresh().count == 5)
        #expect(await stub.requests.count == 2)
    }

    @Test func changingOrRemovingTheKeyCannotReuseAnotherAccountsVoices() async throws {
        let stub = ElevenLabsTransportStub([(200, ElevenLabsFixtures.voices), (200, Data(#"{"voices":[]}"#.utf8))])
        let key = Mutex<String?>("first")
        let cache = ElevenLabsVoiceCache(key: { key.withLock { $0 } }, client: { stub.client(key: $0) })
        #expect(try await cache.voices().count == 5)
        key.withLock { $0 = "second" }
        #expect(try await cache.voices().isEmpty)
        key.withLock { $0 = nil }
        do {
            _ = try await cache.voices()
            Issue.record("Expected missing key")
        } catch { #expect(error as? ElevenLabsError == .invalidKey) }
        let requests = await stub.requests
        #expect(requests.count == 2)
        #expect(requests.first?.value(forHTTPHeaderField: "xi-api-key") == "first")
        #expect(requests.last?.value(forHTTPHeaderField: "xi-api-key") == "second")
    }
}
