import Foundation
import Testing
@testable import Clip_Builder

struct DubSynthesizerTests {
    @Test func cacheIdentityIncludesLanguageVoiceRateAndExactText() throws {
        let name = try DubSynthesizer.cacheName(language: "pt-BR", voice: "voice", rate: 1, text: "Olá")
        #expect(name.count == 68 && name.hasSuffix(".caf"))
        #expect(try DubSynthesizer.cacheName(language: "pt-BR", voice: "voice", rate: 1, text: "Olá") == name)
        #expect(try DubSynthesizer.cacheName(language: "pt-PT", voice: "voice", rate: 1, text: "Olá") != name)
        #expect(try DubSynthesizer.cacheName(language: "pt-BR", voice: "other", rate: 1, text: "Olá") != name)
        #expect(try DubSynthesizer.cacheName(language: "pt-BR", voice: "voice", rate: 1.2, text: "Olá") != name)
        #expect(try DubSynthesizer.cacheName(language: "pt-BR", voice: "voice", rate: 1, text: "Olá!") != name)
    }

    @Test("Mac voice writes a reusable CAF and restores a cleared cache",
          .enabled(if: !DubSynthesizer.installedVoices(language: "pt-BR").isEmpty,
                   "No Portuguese (Brazil) Mac voice is installed."))
    func speechSmoke() async throws {
        let temp = try TempDirectory()
        let synthesizer = DubSynthesizer(directory: temp.url)
        let voice = try #require(DubSynthesizer.installedVoices(language: "pt-BR").first)
        let text = "Olá, este é um teste de tradução para português."
        let url = try await synthesizer.synthesize(text: text, voice: voice.identifier, rate: 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let duration = try await synthesizer.duration(of: url)
        #expect(duration > 0.5 && duration < 30)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let again = try await synthesizer.synthesize(text: text, voice: voice.identifier, rate: 1)
        #expect(url == again)
        #expect(try FileManager.default.attributesOfItem(atPath: again.path)[.modificationDate] as? Date
            == attributes[.modificationDate] as? Date)
        try FileManager.default.removeItem(at: url)
        let line = DubLine(clipUID: UUID(), speakerKey: "unknown", voice: voice.identifier, text: text,
            sourceStart: 0, sourceEnd: duration, start: 1, duration: duration, audio: url.lastPathComponent)
        let restored = try await synthesizer.restoringAudio(lines: [line])
        #expect(restored.first?.audio == url.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect((restored.first?.duration ?? 0) > 0.5)
    }
}
