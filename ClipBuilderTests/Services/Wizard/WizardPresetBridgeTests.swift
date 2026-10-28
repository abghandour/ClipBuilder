import Foundation
import Testing
@testable import Clip_Builder

@Suite("Express and Wizard presets bridge")
struct WizardPresetBridgeTests {
    @Test func oldFramingPresetsMigrateAndNewFramingWins() throws {
        let fields: [String: JSONSetting] = ["highlightFraming": .string("interview_focus"),
                                             "interviewZoom": .number(0.7), "interviewCuts": .bool(true)]
        let converted = WizardPresetBridge.miniSettings(from: fields)
        #expect(converted.framing == Framing(subject: .speakerFocus, pullBack: 0.7, moves: .cuts))
        var newFields = fields
        newFields["framing"] = .string("{}")
        #expect(WizardPresetBridge.miniSettings(from: newFields).framing == Framing())
        #expect(WizardPresetBridge.miniSettings(from: ["highlightFraming": .string("grid")]).framing.layout == "Split")
        #expect(AISettingsEnvelope.keys(.options, kind: .wizard).contains("framing"))

        let suite = "FramingDefaultsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var options = WizardOptions()
        options.framing = Framing(subject: .vipFocus)
        WizardExpressExtras.apply(to: &options, defaults: defaults)
        #expect(options.framing == Framing(subject: .vipFocus))
        #expect(Framing.split(defaults.string(forKey: WizardExpressExtras.framingKey)) == options.framing)
        var replay = WizardOptions()
        replay.podcastFraming = .original
        WizardExpressExtras.apply(to: &replay, defaults: defaults)
        #expect(replay.framing == options.framing)

        AISettingsPreferences.write(fields, kind: .wizard, defaults: defaults)
        #expect(Framing.split(defaults.string(forKey: WizardExpressExtras.framingKey)) == converted.framing)
        let snapshot = try #require(defaults.string(forKey: AISettingsPreferences.snapshotKey))
        #expect(try JSONDecoder().decode(WizardOptions.self, from: Data(snapshot.utf8)).framing == converted.framing)
        let fresh = Framing(subject: .centerStage, fit: .blurredFill, blur: 0.8)
        AISettingsPreferences.write(["framing": JSONSetting.dictionaryValue(fresh)], kind: .wizard, defaults: defaults)
        #expect(Framing.split(defaults.string(forKey: WizardExpressExtras.framingKey)) == fresh)
        AISettingsPreferences.write(fields, kind: .wizard, scopes: [.prompts], defaults: defaults)
        #expect(Framing.split(defaults.string(forKey: WizardExpressExtras.framingKey)) == fresh)
    }

    private var express: MiniWizardSettings {
        var settings = MiniWizardSettings()
        settings.quality = .compact
        settings.preset = .square1080
        settings.framing = Framing(subject: .original, fit: .blurredFill, feather: 0.12, blur: 0.9)
        settings.captions = true
        settings.captionPosition = "bottom"
        settings.captionStyleID = "bold"
        settings.englishCaptions = true
        settings.introVideo = true
        settings.introBumper = "bumpers/intro.mp4"
        settings.nameTags = true
        settings.nameTagStyleID = "pill"
        settings.safeAreaOnly = true
        settings.safeAreaPlatforms = ["instagram", "tiktok"]
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
        #expect(fields["podcastFraming"] == nil && fields["highlightFraming"] == nil)
        #expect(fields["transitionChoice"] == .string("fadeblack") && fields["lookPreset"] == .string("vintage"))
        #expect(fields["fixedOverlayTextsJoined"] == .string("Hook\nSecond"))
        #expect(fields["outputMode"] == .string("oneReel"))
        #expect(Framing.split(fields["framing"]?.string) == express.framing)
        let back = WizardPresetBridge.miniSettings(from: fields)
        #expect(back == express)
    }

    @Test func wizardFieldsFillExpressAndMissingKeysKeepDefaults() {
        var settings = WizardPresetBridge.miniSettings(from: [
            "highlightFraming": .string("grid"), "podcastFraming": .string("followSpeaker"),
            "addCaptions": .bool(true), "captionLanguage": .null, "includeWatermark": .bool(false),
            "lookPreset": .string("bw"), "transitionChoice": .string("random"),
        ])
        #expect(settings.framing.subject == .layout && settings.captions && !settings.englishCaptions)
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

extension WizardPresetBridgeTests {
    @Test func dubToggleAndRememberedLanguageRoundTripThroughPresets() {
        for enabled in [true, false] {
            var settings = MiniWizardSettings()
            settings.dub = enabled; settings.dubLanguage = "pt-BR"
            let fields = WizardPresetBridge.wizardFields(from: settings)
            #expect(fields["dubLanguage"] == (enabled ? .string("pt-BR") : .string("")))
            #expect(WizardPresetBridge.miniSettings(from: fields) == settings)
        }
        let imported = WizardPresetBridge.miniSettings(from: ["dubLanguage": .string("en-US")])
        #expect(imported.dub && imported.dubLanguage == "en-US")
        let disabled = WizardPresetBridge.miniSettings(from: ["dubLanguage": .null], base: imported)
        #expect(!disabled.dub && disabled.dubLanguage == nil)
    }
}
