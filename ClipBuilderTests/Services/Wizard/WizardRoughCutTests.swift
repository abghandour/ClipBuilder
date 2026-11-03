import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard rough cut")
struct WizardRoughCutTests {
    @Test("every presentation layer is off and the canvas is a third of the size, aspect kept")
    func optionsKeepFramingOnly() {
        var options = WizardOptions()
        options.renderSettings.preset = .portrait1080
        options.renderSettings.quality = .archival
        options.renderSettings.speechPolish = SpeechPolishSettings()
        options.addCaptions = true
        options.enableTextOverlays = true
        options.nameTags = true
        options.useMusic = true
        options.musicTrack = "Beat"
        options.muteSource = true
        options.dubLanguage = "pt"
        options.includeWatermark = true
        options.includeIntroBumper = true
        options.introBumperPath = "/tmp/intro.mp4"
        options.watermarkOverlayTemplate = "Mark"
        options.fixedOverlayTemplate = "Lower Third"
        options.strikeStats = true
        options.lookPreset = "vintage"
        options.useBRoll = true
        options.transitionChoice = "fadeblack"
        options.framing = Framing(subject: .speakerFocus)
        options.interviewZoom = 0.4
        options.interviewCuts = true

        let rough = WizardRoughCut.options(options)
        #expect(rough.renderSettings.width == 360 && rough.renderSettings.height == 640)
        #expect(rough.renderSettings.quality == .compact && rough.renderSettings.speechPolish == nil)
        #expect(!rough.addCaptions && !rough.enableTextOverlays && rough.nameTags == false && !rough.usesNameTags)
        #expect(!rough.useMusic && rough.musicTrack == nil && !rough.muteSource && rough.dubLanguage == nil)
        #expect(!rough.includeWatermark && !rough.includeIntroBumper && rough.introBumperPath == nil)
        #expect(rough.watermarkOverlayTemplate == nil && rough.fixedOverlayTemplate == nil)
        #expect(rough.strikeStats == false && rough.lookPreset == nil && !rough.useBRoll)
        #expect(rough.transitionChoice == nil && rough.allowedTransitions == ["cut"])
        // Framing is the point of a rough cut.
        #expect(rough.framing?.subject == .speakerFocus && rough.interviewZoom == 0.4 && rough.interviewCuts == true)
    }

    @Test("a small canvas keeps its aspect: one factor for both sides, floor on the short side")
    func smallCanvasFloor() {
        var options = WizardOptions()
        options.renderSettings.preset = .custom
        options.renderSettings.customWidth = 500
        options.renderSettings.customHeight = 250
        let rough = WizardRoughCut.options(options)
        #expect(rough.renderSettings.width == 480 && rough.renderSettings.height == 240)
        options.renderSettings.customWidth = 300
        options.renderSettings.customHeight = 240
        let tiny = WizardRoughCut.options(options)
        #expect(tiny.renderSettings.width == 300 && tiny.renderSettings.height == 240, "never upscaled")
    }

    @Test("the built document loses overlays, sound, dub, effects, cutaways and captions")
    func stripDocument() {
        var document = TimelineDocument()
        var card = TimelineClip()
        card.videoFile = "/tmp/cards/intro_card.mp4"
        card.duration = 2
        var main = TimelineClip()
        main.sceneID = 7
        main.startTime = 2
        main.duration = 5
        main.captions = "bottom"
        main.effect = EffectSpec(preset: "vintage")
        main.transIn = "fade"
        main.transOut = "fadeblack"
        var cutaway = TimelineClip()
        cutaway.role = .cutaway
        cutaway.track = 1
        document.videoTrack = [card, main, cutaway]
        document.textOverlays = [TextOverlayItem()]
        document.overlayBlocks = [OverlayBlockItem()]
        document.soundTrack = [SoundItem()]
        document.dub = DubSettings(language: "pt")
        document.renderSettings.speechPolish = SpeechPolishSettings()

        let rough = WizardRoughCut.strip(document)
        #expect(rough.videoTrack.count == 1 && rough.videoTrack[0].sceneID == 7, "card and cutaway gone")
        #expect(rough.videoTrack[0].startTime == 0, "the card's gap closes")
        #expect(rough.videoTrack[0].captions == "none" && rough.videoTrack[0].effect == nil)
        #expect(rough.videoTrack[0].transIn == nil && rough.videoTrack[0].transOut == nil)
        #expect(rough.textOverlays.isEmpty && rough.overlayBlocks.isEmpty && rough.soundTrack.isEmpty)
        #expect(rough.dub == nil && rough.renderSettings.speechPolish == nil)
    }
}
