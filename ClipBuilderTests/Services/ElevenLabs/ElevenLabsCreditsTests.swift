import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

struct ElevenLabsCreditsTests {
    @Test func countsOnlyLinesWithoutAudioOrWithChangedText() {
        let cached = Self.line(text: "Hello", audio: "cached.caf")
        let pending = Self.line(text: "Olá 👋", audio: nil)
        let original = [cached, pending]
        #expect(ElevenLabsDubUsage.pendingCharacters(lines: original, cachedLines: original, voices: [:]) == 5)

        var edited = cached
        edited.text = "Bonjour"
        #expect(ElevenLabsDubUsage.pendingCharacters(lines: [edited, pending], cachedLines: original, voices: [:]) == 12)
        edited.text = cached.text
        #expect(ElevenLabsDubUsage.pendingCharacters(lines: [edited], cachedLines: original, voices: [:]) == 0)
        edited.audio = nil
        #expect(ElevenLabsDubUsage.pendingCharacters(lines: [edited], cachedLines: original, voices: [:]) == 5)
    }

    @Test func countsVoiceOverridesAndSpeakerReassignmentUsingTheEffectiveVoice() {
        let cached = Self.line(text: "Hello", audio: "cached.caf")
        let original = [cached]
        let changedVoice = [cached.speakerKey: "elevenlabs:other"]
        #expect(ElevenLabsDubUsage.pendingCharacters(lines: original, cachedLines: original, voices: changedVoice) == 5)

        var moved = cached
        moved.speakerKey = "guest"
        #expect(ElevenLabsDubUsage.pendingCharacters(lines: [moved], cachedLines: original, voices: ["guest": "elevenlabs:other"]) == 5)
        #expect(ElevenLabsDubUsage.pendingCharacters(lines: [moved], cachedLines: original, voices: ["guest": cached.voice]) == 0)

        moved.voice = "elevenlabs:other"
        #expect(ElevenLabsDubUsage.pendingCharacters(lines: [moved], cachedLines: original, voices: [:]) == 5)
    }

    @Test func timingChangesReuseAudioAndUnknownLinesCount() {
        let cached = Self.line(text: "Hello", audio: "cached.caf")
        var retimed = cached
        retimed.rate = 1.2
        retimed.stretch = 1.1
        retimed.start = 2
        #expect(ElevenLabsDubUsage.pendingCharacters(lines: [retimed], cachedLines: [cached], voices: [:]) == 0)
        #expect(ElevenLabsDubUsage.pendingCharacters(lines: [cached], cachedLines: [], voices: [:]) == 5)
        #expect(ElevenLabsDubUsage.pendingCharacters(lines: [], cachedLines: [], voices: [:]) == 0)
    }

    @Test func subscriptionCacheKeepsTheLastSuccessAcrossFailedChecks() async throws {
        let stub = ElevenLabsTransportStub([(200, ElevenLabsFixtures.subscription), (503, Data())])
        let cache = ElevenLabsSubscriptionCache(key: { "fixture-key" }, client: { stub.client(key: $0) })
        #expect(await cache.lastSuccessful() == nil)
        let subscription = try await cache.refresh()
        #expect(subscription.characterLimit - subscription.characterCount == 29880)
        #expect(await cache.lastSuccessful() == subscription)
        do {
            _ = try await cache.refresh()
            Issue.record("Expected failed subscription check")
        } catch { #expect(error as? ElevenLabsError == .http(503)) }
        #expect(await cache.lastSuccessful() == subscription)
        #expect(await stub.requests.count == 2)
    }

    @Test func subscriptionCacheDiscardsAnotherAccountsBalance() async throws {
        let stub = ElevenLabsTransportStub([(200, ElevenLabsFixtures.subscription), (200, ElevenLabsFixtures.subscription)])
        let key = Mutex<String?>("first")
        let cache = ElevenLabsSubscriptionCache(key: { key.withLock { $0 } }, client: { stub.client(key: $0) })
        _ = try await cache.refresh()
        key.withLock { $0 = "second" }
        #expect(await cache.lastSuccessful() == nil)
        _ = try await cache.refresh()
        key.withLock { $0 = nil }
        #expect(await cache.lastSuccessful() == nil)
        do {
            _ = try await cache.refresh()
            Issue.record("Expected missing key")
        } catch { #expect(error as? ElevenLabsError == .invalidKey) }
        #expect(await stub.requests.count == 2)
    }

    private nonisolated static func line(text: String, audio: String?) -> DubLine {
        DubLine(clipUID: UUID(), speakerKey: "host", voice: "elevenlabs:voice", text: text,
                sourceStart: 0, sourceEnd: 1, start: 0, duration: 1, audio: audio)
    }
}
