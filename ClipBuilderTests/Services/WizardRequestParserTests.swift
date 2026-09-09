import Foundation
import Testing
@testable import Clip_Builder

struct WizardRequestParserTests {
    @Test func confidentRequestDoesNotCallModel() async throws {
        let stub = try StubAI(response: "{}")
        let engine = WizardEngine(ai: stub.service, render: RenderEngine())
        let result = try await engine.parseRequest(description: "30 seconds no music", profile: BrandProfile(name: "Test"), emit: { _ in }, useLocal: true)
        #expect(result.targetDurationSeconds == 30)
        #expect(result.useMusic == false)
        #expect(!FileManager.default.fileExists(atPath: stub.calls.path))
    }
    @Test(arguments: ["30s", "30 seconds", "30-second video", "thirty"])
    func numericDuration(_ text: String) {
        let result = WizardRequestParser.parse(text, tags: [], templates: [])
        #expect(result.request.targetDurationSeconds == (text == "thirty" ? nil : 30))
    }
    @Test(arguments: ["one minute", "1 min", "um minuto", "60 segundos"])
    func minute(_ text: String) {
        #expect(WizardRequestParser.parse(text, tags: [], templates: []).request.targetDurationSeconds == 60)
    }
    @Test(arguments: ["caption \"Hello!\"", "title “Hello!”", "saying 'Hello!'", "legenda \"Hello!\""])
    func overlay(_ text: String) {
        let request = WizardRequestParser.parse(text, tags: [], templates: []).request
        #expect(request.overlayText == "Hello!")
        #expect(request.addCaptions == nil)
        #expect(request.enableTextOverlays == true)
    }
    @Test func requests() {
        #expect(WizardRequestParser.parse("1:30", tags: [], templates: []).request.targetDurationSeconds == 90)
        #expect(WizardRequestParser.parse("subtitles no music", tags: [], templates: []).request.addCaptions == true)
        #expect(WizardRequestParser.parse("subtitles no music", tags: [], templates: []).request.useMusic == false)
        #expect(WizardRequestParser.parse("um vídeo de 30 segundos com a legenda \"Porrada day!\" sem música", tags: [], templates: []).confident)
        #expect(!WizardRequestParser.parse("quick recap, punchy, dark mood", tags: [], templates: []).confident)
        #expect(WizardRequestParser.parse("fight footage only", tags: ["fight", "fight-footage"], templates: []).request.contentTags == ["fight", "fight-footage"])
    }
}

extension WizardRequestParserTests {
    @Test func offPathStillAsksTheModel() async throws {
        let stub = try StubAI(response: "{}")
        let engine = WizardEngine(ai: stub.service, render: RenderEngine())
        let result = try await engine.parseRequest(description: "30 seconds no music", profile: BrandProfile(name: "Test"), emit: { _ in }, useLocal: false)
        #expect(try String(contentsOf: stub.calls, encoding: .utf8) == "call\n")
        #expect(result.targetDurationSeconds == nil)
        #expect(result.useMusic == nil)
    }
    @Test func unsureRequestMergesLocalFieldsUnderTheModel() async throws {
        let stub = try StubAI(response: #"{"use_music":false,"residual_instructions":"punchy dark mood"}"#)
        let engine = WizardEngine(ai: stub.service, render: RenderEngine())
        let description = "a punchy, dark, moody, fast, loud, gritty, dramatic recap lasting 45 seconds please"
        #expect(!WizardRequestParser.parse(description, tags: [], templates: []).confident)
        let result = try await engine.parseRequest(description: description, profile: BrandProfile(name: "Test"), emit: { _ in }, useLocal: true)
        #expect(try String(contentsOf: stub.calls, encoding: .utf8) == "call\n")
        #expect(result.targetDurationSeconds == 45)
        #expect(result.useMusic == false)
        #expect(result.residualInstructions == "punchy dark mood")
    }
    @Test func mergePrefersModelAndFillsGaps() {
        var model = ParsedWizardRequest()
        model.targetDurationSeconds = 20
        model.useMusic = true
        var local = ParsedWizardRequest()
        local.targetDurationSeconds = 30
        local.useMusic = false
        local.addCaptions = true
        local.contentTags = ["fight"]
        let merged = WizardRequestParser.merge(model, local: local)
        #expect(merged.targetDurationSeconds == 20)
        #expect(merged.useMusic == true)
        #expect(merged.addCaptions == true)
        #expect(merged.contentTags == ["fight"])
        model.contentTags = ["training"]
        #expect(WizardRequestParser.merge(model, local: local).contentTags == ["training"])
    }
    @Test func templateMatchesByNearName() {
        let result = WizardRequestParser.parse("30s using the fight-night template", tags: [], templates: ["Fight Night", "Podcast Quote"])
        #expect(result.request.overlayTemplate == "Fight Night")
        #expect(result.request.enableTextOverlays == true)
        #expect(WizardRequestParser.parse("30s with a big title", tags: [], templates: ["Fight Night"]).request.overlayTemplate == nil)
    }
    @Test func durationIsClamped() {
        #expect(WizardRequestParser.parse("1 second", tags: [], templates: []).request.targetDurationSeconds == 3)
        #expect(WizardRequestParser.parse("10 minutes", tags: [], templates: []).request.targetDurationSeconds == 180)
        #expect(WizardRequestParser.parse("5:00", tags: [], templates: []).request.targetDurationSeconds == 180)
    }
}
