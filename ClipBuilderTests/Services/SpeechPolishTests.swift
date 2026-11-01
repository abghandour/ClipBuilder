import Foundation
import Testing
@testable import Clip_Builder

struct SpeechPolishTests {
    @Test("filter chain per strength")
    func filterPerStrength() {
        let expected: [SpeechPolishSettings.Strength: String] = [
            .light: "highpass=f=80,afftdn=nr=6:nf=-40,loudnorm=I=-16:TP=-1.5:LRA=11",
            .standard: "highpass=f=80,afftdn=nr=9:nf=-40,loudnorm=I=-16:TP=-1.5:LRA=11",
            .strong: "highpass=f=80,afftdn=nr=12:nf=-40,loudnorm=I=-16:TP=-1.5:LRA=11",
        ]
        for strength in SpeechPolishSettings.Strength.allCases {
            #expect(SpeechPolish.filter(SpeechPolishSettings(enabled: true, strength: strength)) == expected[strength])
        }
    }

    @Test("arguments copy video and re-encode filtered audio")
    func argumentShape() {
        let input = URL(fileURLWithPath: "/tmp/in.mp4")
        let output = URL(fileURLWithPath: "/tmp/out.mp4")
        let settings = SpeechPolishSettings(enabled: true, strength: .strong)
        let arguments = SpeechPolish.arguments(input: input, output: output, settings: settings)
        #expect(Array(arguments.prefix(3)) == ["-y", "-i", input.path])
        #expect(arguments.last == output.path)
        let videoCopy = try? #require(arguments.firstIndex(of: "-c:v"))
        #expect(videoCopy.map { arguments[$0 + 1] } == "copy")
        let filter = arguments.firstIndex(of: "-af").map { arguments[$0 + 1] }
        #expect(filter == SpeechPolish.filter(settings))
        #expect(arguments.contains("0:a"))
        // The app's standard AAC settings, including the 44.1 kHz resample.
        let audio = FFmpeg.audioEncodeArgs
        let start = arguments.firstIndex(of: "-c:a")
        #expect(start.map { Array(arguments[$0..<($0 + audio.count)]) } == audio)
        #expect(arguments.contains("44100"))
        #expect(arguments.contains("+faststart"))
    }

    @Test("settings decode without strength default to standard")
    func settingsDecodeWithoutStrength() throws {
        let decoded = try JSONDecoder().decode(SpeechPolishSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(decoded == SpeechPolishSettings(enabled: true, strength: .standard))
        let unknown = try JSONDecoder().decode(SpeechPolishSettings.self,
                                               from: Data(#"{"enabled":true,"strength":"extreme"}"#.utf8))
        #expect(unknown.strength == .standard)
    }

    @Test("render settings decode without the key and round-trip with it")
    func renderSettingsDecoding() throws {
        let old = try JSONDecoder().decode(RenderSettings.self,
                                           from: Data(#"{"preset":"portrait1080","quality":"balanced"}"#.utf8))
        #expect(old.speechPolish == nil)
        var settings = RenderSettings()
        settings.speechPolish = SpeechPolishSettings(enabled: true, strength: .light)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(RenderSettings.self, from: data) == settings)
        // Unset polish adds nothing to the encoded settings (finishing cache keys stay put).
        let plain = try JSONEncoder().encode(RenderSettings())
        #expect(!(String(data: plain, encoding: .utf8) ?? "").contains("speechPolish"))
    }

    @Test("finishing cache settings ignore the polish choice")
    func finishingSettingsStripPolish() {
        var settings = RenderSettings()
        settings.speechPolish = SpeechPolishSettings(enabled: true, strength: .strong)
        #expect(MultitrackRenderer.finishingSettings(settings) == RenderSettings())
    }

    @Test("wizard default: spoken sources and recipes on, fight material never")
    func wizardDefault() {
        let on = SpeechPolishSettings(enabled: true, strength: .standard)
        #expect(SpeechPolish.wizardDefault(recipeID: "podcast", sourceTypes: []) == on)
        #expect(SpeechPolish.wizardDefault(recipeID: "podcast_highlights", sourceTypes: [nil]) == on)
        #expect(SpeechPolish.wizardDefault(recipeID: "interview", sourceTypes: [.interview]) == on)
        #expect(SpeechPolish.wizardDefault(recipeID: "custom", sourceTypes: [.podcast, .interview, nil]) == on)
        #expect(SpeechPolish.wizardDefault(recipeID: "custom", sourceTypes: [.podcast, .other]) == nil)
        #expect(SpeechPolish.wizardDefault(recipeID: "custom", sourceTypes: [nil]) == nil)
        #expect(SpeechPolish.wizardDefault(recipeID: "custom", sourceTypes: []) == nil)
        #expect(SpeechPolish.wizardDefault(recipeID: "mma-finish", sourceTypes: [.podcast]) == nil)
        #expect(SpeechPolish.wizardDefault(recipeID: "podcast", sourceTypes: [.podcast, .fight]) == nil)
        #expect(SpeechPolish.wizardDefault(recipeID: "interview", sourceTypes: [.training]) == nil)
        #expect(SpeechPolish.wizardDefault(recipeID: nil, sourceTypes: [.recap]) == nil)
    }
}
