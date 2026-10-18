import Foundation
import Testing
@testable import Clip_Builder

@Suite("Express and Wizard presets bridge")
struct WizardPresetBridgeTests {
    private var express: MiniWizardSettings {
        var settings = MiniWizardSettings()
        settings.quality = .compact
        settings.preset = .square1080
        settings.cameraFocus = WizardCameraFocus.original
        settings.captions = true
        settings.captionPosition = "bottom"
        settings.captionStyleID = "bold"
        settings.englishCaptions = true
        settings.introVideo = true
        settings.introBumper = "bumpers/intro.mp4"
        settings.nameTags = true
        settings.nameTagStyleID = "pill"
        settings.watermark = true
        settings.watermarkOverlay = "Mark"
        settings.watermarkOpacity = 0.3
        settings.overlay = true
        settings.overlayTemplate = "Lower Third"
        settings.overlayStart = 1.5
        settings.overlayDuration = 4
        settings.overlayTexts = ["Hook", "Second"]
        settings.transition = "fadeblack"
        settings.look = "vintage"
        settings.outputMode = .oneReel
        return settings
    }

    @Test func expressSettingsRoundTripThroughTheWizardShape() {
        let fields = WizardPresetBridge.wizardFields(from: express)
        #expect(fields["addCaptions"] == .bool(true) && fields["captionLanguage"] == .string("en"))
        #expect(fields["podcastFraming"] == .string("original") && fields["highlightFraming"] == .null)
        #expect(fields["transitionChoice"] == .string("fadeblack") && fields["lookPreset"] == .string("vintage"))
        #expect(fields["fixedOverlayTextsJoined"] == .string("Hook\nSecond"))
        #expect(fields["outputMode"] == .string("oneReel"))
        let back = WizardPresetBridge.miniSettings(from: fields)
        #expect(back == express)
    }

    @Test func wizardFieldsFillExpressAndMissingKeysKeepDefaults() {
        var settings = WizardPresetBridge.miniSettings(from: [
            "highlightFraming": .string("grid"), "podcastFraming": .string("followSpeaker"),
            "addCaptions": .bool(true), "captionLanguage": .null, "includeWatermark": .bool(false),
            "lookPreset": .string("bw"), "transitionChoice": .string("random"),
        ])
        #expect(settings.cameraFocus == "grid" && settings.captions && !settings.englishCaptions)
        #expect(!settings.watermark && settings.look == "bw" && settings.transition == "random")
        #expect(settings.outputMode == .separateVideos && settings.quality == .balanced)
        // Custom render values fall back to Express's allowed ones.
        var render = RenderSettings()
        render.quality = .custom
        render.preset = .custom
        settings = WizardPresetBridge.miniSettings(from: ["renderSettings": JSONSetting.dictionaryValue(render)])
        #expect(settings.quality == .balanced && settings.preset == .portrait1080)
        #expect(WizardPresetBridge.miniSettings(from: [:]) == MiniWizardSettings())
    }

    @Test func presetListsConvertBothWays() {
        let mini = [MiniWizardPreset(name: "Podcast", savedAt: Date(timeIntervalSince1970: 5), settings: express)]
        let wizard = WizardPresetBridge.wizardPresets(from: mini)
        #expect(wizard.map(\.name) == ["Podcast"] && wizard[0].settings["lookPreset"] == .string("vintage"))
        let back = WizardPresetBridge.miniPresets(from: wizard)
        #expect(back[0].settings == express && back[0].savedAt == mini[0].savedAt)
    }
}
