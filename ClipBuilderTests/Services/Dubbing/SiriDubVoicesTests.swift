import Foundation
import Testing
@testable import Clip_Builder

struct SiriDubVoicesTests {
    @Test func naturalAssetsBecomeRankedVoicesAndSiriOwnAssetsAreIgnored() {
        let voices = SiriDubVoices.voices(fromSpecifiers: [
            "com.apple.siri.tts.voice.pt_BR.sandra.natural.premium",
            "com.apple.siri.tts.voice.pt_BR.nando.gryphon.premium",
            "com.apple.siri.tts.voice.pt_BR.nando.natural.premium",
            "com.apple.siri.tts.voice.en_US.aaron.natural.premium",
            "com.apple.siri.tts.resource.pt_BR",
            "com.apple.siri.tts.customvoice.global",
            "com.apple.siri.tts.voice.pt_BR.sandra.natural.premium",
        ])
        #expect(voices.map(\.identifier) == ["com.apple.siri.natural.Aaron", "com.apple.siri.natural.Nando",
                                             "com.apple.siri.natural.Sandra"])
        #expect(voices.map(\.language) == ["en-US", "pt-BR", "pt-BR"])
        #expect(voices.map(\.gender) == [.male, .male, .female])
        #expect(voices.allSatisfy { $0.quality == 3 && $0.qualityLabel == "Siri" })
        #expect(voices.allSatisfy { SiriDubVoices.isSiri($0.identifier) })
        #expect(!SiriDubVoices.isSiri("com.apple.voice.enhanced.pt-BR.Felipe"))
    }

    @Test func shortcutNamesAndReadinessFollowTheConvention() {
        let voices = SiriDubVoices.voices(fromSpecifiers: ["com.apple.siri.tts.voice.pt_BR.nando.natural.premium",
                                                           "com.apple.siri.tts.voice.pt_BR.sandra.natural.premium"])
        #expect(SiriDubVoices.shortcutName(for: "com.apple.siri.natural.Nando") == "Clip Builder Dub Nando")
        let ready = SiriDubVoices.readyVoices(downloaded: voices, shortcuts: ["Clip Builder Dub Sandra", "Other"])
        #expect(ready.map(\.name) == ["Sandra"])
        let status = SiriDubVoices.Status(language: "pt-BR", ffmpegInstalled: true, downloaded: voices,
                                          shortcuts: ["Clip Builder Dub Sandra"])
        #expect(status.missingShortcuts.map(\.name) == ["Nando"] && status.isReady)
        #expect(!SiriDubVoices.Status(language: "pt-BR", ffmpegInstalled: false, downloaded: voices,
                                      shortcuts: ["Clip Builder Dub Sandra"]).isReady)
        #expect(SiriDubVoices.shortcutsLabel(for: voices[0]) == "Voice 1")
        #expect(SiriDubVoices.shortcutsLabel(for: voices[1]) == "Voice 2")
        #expect(SiriDubVoices.manualSteps(for: voices[1]).contains { $0.contains("“Clip Builder Dub Sandra”") })
    }

    @Test func shortcutDefinitionSpeaksShortcutInputWithTheVoice() throws {
        let voice = DubSynthesizer.Voice(identifier: "com.apple.siri.natural.Nando", language: "pt-BR", name: "Nando")
        let definition = SiriDubVoices.shortcutDefinition(for: voice)
        let data = try PropertyListSerialization.data(fromPropertyList: definition, format: .binary, options: 0)
        let decoded = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let actions = try #require(decoded["WFWorkflowActions"] as? [[String: Any]])
        #expect(actions.map { $0["WFWorkflowActionIdentifier"] as? String }
            == ["is.workflow.actions.makespokenaudiofromtext", "is.workflow.actions.output"])
        let speak = try #require(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        #expect(speak["WFSpeakTextVoice"] as? String == voice.identifier)
        #expect(speak["WFSpeakTextLanguage"] as? String == "pt-BR")
        let input = try #require(speak["WFInput"] as? [String: Any])
        let attachments = try #require((input["Value"] as? [String: Any])?["attachmentsByRange"] as? [String: [String: Any]])
        #expect(attachments["{0, 1}"]?["Type"] as? String == "ExtensionInput")
    }

    @Test func conversionAppliesTempoOnlyAboveUnity() {
        let input = URL(fileURLWithPath: "/tmp/in.m4a"), output = URL(fileURLWithPath: "/tmp/out.caf")
        let plain = SiriDubSynthesizer.conversionArguments(input: input, output: output, rate: 1)
        #expect(!plain.contains("-filter:a") && plain.suffix(2) == ["caf", "/tmp/out.caf"])
        let faster = SiriDubSynthesizer.conversionArguments(input: input, output: output, rate: 1.25)
        #expect(faster.contains("atempo=1.2500"))
    }

    @Test func speechForEngineListsOnlyReadyVoicesForSiri() async {
        let siri = await DubPreparation.Speech.forEngine(.siri).voices("pt-BR")
        #expect(siri.allSatisfy { SiriDubVoices.isSiri($0.identifier) })
        let mac = await DubPreparation.Speech.forEngine(.mac).voices("pt-BR")
        #expect(mac.allSatisfy { !SiriDubVoices.isSiri($0.identifier) })
    }

    @Test("Siri voice speaks through its shortcut into the shared cache format",
          .enabled(if: SiriDubVoices.shortcutsSmokeVoice != nil,
                   "No Siri voice with a Clip Builder Dub shortcut is ready on this Mac."))
    func shortcutSmoke() async throws {
        let voice = try #require(SiriDubVoices.shortcutsSmokeVoice)
        let temp = try TempDirectory()
        let synthesizer = DubSynthesizer(directory: temp.url)
        let text = "Olá, este é um teste da voz da Siri para a dublagem."
        let url = try await synthesizer.synthesize(text: text, voice: voice.identifier, rate: 1)
        #expect(url.pathExtension == "caf" && url.deletingLastPathComponent() == temp.url)
        let duration = try await synthesizer.duration(of: url)
        #expect(duration > 1 && duration < 30)
        let faster = try await synthesizer.synthesize(text: text, voice: voice.identifier, rate: 1.25)
        let fasterDuration = try await synthesizer.duration(of: faster)
        #expect(faster != url && fasterDuration < duration * 0.9 && fasterDuration > duration * 0.7)
        #expect(try await synthesizer.synthesize(text: text, voice: voice.identifier, rate: 1) == url)
    }
}

extension SiriDubVoicesTests {
    @Test("Portuguese dub with the Siri engine assigns Siri voices and fits lines through the shortcut",
          .enabled(if: SiriDubVoices.shortcutsSmokeVoice != nil,
                   "No Siri voice with a Clip Builder Dub shortcut is ready on this Mac."))
    func portugueseDubPicksSiriVoices() async throws {
        let clip = Fixtures.timelineClip(sourceStart: 0, duration: 8)
        func row(_ id: Int64, _ start: Double, _ end: Double, _ text: String, _ speaker: String) -> TranscriptRow {
            var row = TranscriptRow(id: id, videoID: 1, language: "pt-BR", isTranslation: true,
                startTime: start, endTime: end, text: text, originalText: nil, wordsJSON: nil, provider: nil, model: nil)
            row.speakerKey = speaker
            return row
        }
        let rows = [row(1, 0, 3, "Bem-vindos ao treino de hoje, vamos começar.", "coach"),
                    row(2, 4, 7, "Estou pronta, vamos nessa com tudo.", "athlete")]
        let prepared = try await DubPreparation.synthesize(document: Fixtures.timelineDocument(clips: [clip]),
            rows: [clip.uid: rows], turns: [:], settings: .init(language: "pt-BR", engine: .siri),
            speech: .forEngine(.siri), genders: ["coach": .male, "athlete": .female])
        #expect(prepared.lines.count == 2)
        for line in prepared.lines {
            #expect(SiriDubVoices.isSiri(line.voice))
            let url = DubSynthesizer.shared.directory.appendingPathComponent(line.audio ?? "")
            #expect(try DubSynthesizer.fileDuration(of: url) > 0.5)
        }
        #expect(prepared.settings.voices.values.allSatisfy(SiriDubVoices.isSiri))
    }

    @Test func siriEngineWithoutReadyVoicesFailsWithTheSetupMessage() async {
        let clip = Fixtures.timelineClip(sourceStart: 0, duration: 4)
        let row = TranscriptRow(id: 1, videoID: 1, language: "pt-BR", isTranslation: true,
            startTime: 0, endTime: 3, text: "Olá", originalText: nil, wordsJSON: nil, provider: nil, model: nil)
        let none = DubPreparation.Speech(voices: { _ in [] }, synthesize: { _, _, _ in URL(fileURLWithPath: "/dev/null") },
                                         duration: { _ in 1 })
        await #expect(throws: ScriptError.invalid(SiriDubVoices.setupMessage(language: "pt-BR"))) {
            try await DubPreparation.synthesize(document: Fixtures.timelineDocument(clips: [clip]),
                rows: [clip.uid: [row]], turns: [:], settings: .init(language: "pt-BR", engine: .siri), speech: none)
        }
    }
}

extension SiriDubVoices {
    /// The first ready Siri voice, resolved once for the smoke test's condition.
    static let shortcutsSmokeVoice: DubSynthesizer.Voice? = {
        let voices = downloadedVoices(language: "pt-BR")
        guard !voices.isEmpty, FileManager.default.isExecutableFile(atPath: shortcutsExecutable.path),
              let output = try? Process.output(shortcutsExecutable, ["list"]) else { return nil }
        let names = Set(output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) })
        return readyVoices(downloaded: voices, shortcuts: names).first
    }()
}

private extension Process {
    static func output(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
