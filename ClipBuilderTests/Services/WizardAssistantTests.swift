import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard assistant")
struct WizardAssistantTests {
    @Test func emptyTextIsRefused() {
        #expect(WizardAssistant.decide(text: "  \n", mode: .express, hasVideo: true, hasScenes: true, running: false)
                == .unavailable("Describe the reel you want."))
    }

    @Test func runningWizardIsRefused() {
        #expect(WizardAssistant.decide(text: "a reel", mode: .full, hasVideo: true, hasScenes: true, running: true)
                == .unavailable("The Wizard is already working."))
    }

    @Test func expressNeedsAVideo() {
        #expect(WizardAssistant.decide(text: "a reel", mode: .express, hasVideo: false, hasScenes: true, running: false)
                == .unavailable("Choose a source video in Express first."))
        #expect(WizardAssistant.decide(text: "a reel", mode: .express, hasVideo: true, hasScenes: false, running: false) == .send)
    }

    @Test func fullNeedsScenes() {
        #expect(WizardAssistant.decide(text: "a reel", mode: .full, hasVideo: false, hasScenes: false, running: false)
                == .unavailable("Analyze a source first so the Wizard has scenes to pick from."))
        #expect(WizardAssistant.decide(text: "a reel", mode: .full, hasVideo: false, hasScenes: true, running: false) == .send)
    }

    @Test func expressPatchSetsPictureAndAudioControls() {
        var settings = MiniWizardSettings()
        var length = MiniWizardFlow.Length.automatic
        var kind = MiniWizardFlow.FootageKind.qa
        var instructions: String?
        WizardAssistant.applyExpress([
            "footageKind": "highlights", "length": "30", "quality": "compact", "canvas": "square1080",
            "look": "vintage", "transition": "Dissolve", "framing": "centerStage",
            "captions": "true", "captionPosition": "top", "captionStyle": "default", "captionLanguage": "english",
            "nameTags": "true", "nameTagPosition": "topTrailing", "nameTagStyle": "ABCDEF",
            "safeAreaOnly": "true", "watermark": "false", "watermarkDesign": "Lower third", "watermarkOpacity": "40",
            "overlay": "true", "overlayDesign": "Promo", "introVideo": "true", "outroVideo": "false",
            "muteSourceAudio": "true", "music": "true", "dub": "true", "dubLanguage": "en-US",
            "aiInstructions": "the best counters",
        ], settings: &settings, length: &length, instructions: &instructions, footageKind: &kind)
        #expect(kind == .highlights && length == .thirty)
        #expect(settings.quality == .compact && settings.preset == .square1080 && settings.look == "vintage")
        #expect(settings.transition == "Dissolve" && settings.framing.subject == .centerStage)
        #expect(settings.captions && settings.captionPosition == "top" && settings.captionStyleID == nil && settings.englishCaptions)
        #expect(settings.nameTags && settings.nameTagPosition == "topTrailing" && settings.nameTagStyleID == "ABCDEF")
        #expect(settings.safeAreaOnly && !settings.watermark && settings.watermarkOverlay == "Lower third" && settings.watermarkOpacity == 0.4)
        #expect(settings.overlay && settings.overlayTemplate == "Promo" && settings.introVideo && !settings.outroVideo)
        #expect(settings.muteSourceAudio && settings.music && settings.dub && settings.dubLanguage == "en-US")
        #expect(instructions == "the best counters")

        // "default" clears a choice; unknown values leave the field alone.
        WizardAssistant.applyExpress(["nameTagStyle": "default", "canvas": "hexagon", "dubLanguage": "default"],
                                     settings: &settings, length: &length, instructions: &instructions, footageKind: &kind)
        #expect(settings.nameTagStyleID == nil && settings.preset == .square1080 && settings.dubLanguage == nil)
    }

    @Test func expressWhitelistValuesMatchWhatApplyAccepts() {
        var profile = BrandProfile(name: "T")
        let style = NamedCaptionStyle(name: "Bold", style: CaptionStyle())
        profile.captionStyles = [style]
        let settings = WizardAssistant.expressSettings(profile: profile, overlays: ["Lower third"])
        let captionStyle = settings.first { $0.key == "captionStyle" }
        #expect(captionStyle?.normalize("Bold") == style.id.uuidString)
        #expect(captionStyle?.normalize("profile default") == WizardAssistant.defaultChoice)
        #expect(settings.first { $0.key == "canvas" }?.normalize("9:16 · 1080p") == "portrait1080")
        #expect(settings.first { $0.key == "dubLanguage" }?.normalize("Portuguese (Brazil)") == "pt-BR")
        #expect(settings.first { $0.key == "watermarkOpacity" }?.normalize(150) == nil)
        #expect(settings.first { $0.key == "dubLanguage" }?.normalize("default") == WizardAssistant.defaultChoice)
        #expect(settings.first { $0.key == "nameTagPosition" }?.normalize("Bottom right") == "bottomTrailing")
        #expect(WizardAssistant.expressGuidance.contains(WizardAssistant.findHighlightsAction))
        // Looks are the card's menu, not the whole catalogue; framing follows the source type.
        let looks = settings.first { $0.key == "look" }
        #expect(looks?.normalize("vintage") == "vintage" && looks?.normalize("brightness") == nil)
        let fight = WizardAssistant.expressSettings(profile: profile, overlays: [], sourceType: .fight)
        #expect(fight.first { $0.key == "framing" }?.normalize("centerStage") == nil)
        #expect(fight.first { $0.key == "framing" }?.normalize("vipFocus") == "vipFocus")
        #expect(!fight.map(\.key).contains("outputMode"), "Express renders one reel only")
    }

    @Test func overlayDesignChangeResetsTextsAndEdits() {
        var settings = MiniWizardSettings()
        settings.overlayTemplate = "A"
        settings.overlayTexts = ["custom"]
        var length = MiniWizardFlow.Length.automatic
        var kind = MiniWizardFlow.FootageKind.highlights
        var instructions: String?
        WizardAssistant.applyExpress(["overlayDesign": "B"], settings: &settings, length: &length, instructions: &instructions, footageKind: &kind)
        #expect(settings.overlayTemplate == "B" && settings.overlayTexts.isEmpty && settings.overlayEdits == OverlayEdits())
    }

    // MARK: - Context and suggestions

    private func express(_ edit: (inout WizardAssistant.ExpressSnapshot) -> Void = { _ in }) -> AssistantContext {
        var snapshot = WizardAssistant.ExpressSnapshot()
        snapshot.sourceName = "talk.mov"
        snapshot.sourceSeconds = 600
        snapshot.sourceCount = 1
        snapshot.sceneCount = 12
        edit(&snapshot)
        return WizardAssistant.context(express: snapshot)
    }

    private func full(_ edit: (inout WizardAssistant.FullSnapshot) -> Void = { _ in }) -> AssistantContext {
        var snapshot = WizardAssistant.FullSnapshot()
        snapshot.sourceCount = 2
        snapshot.sceneCount = 40
        edit(&snapshot)
        return WizardAssistant.context(full: snapshot)
    }

    private func ids(_ context: AssistantContext) -> [String] {
        WizardAssistant().suggestions(for: context).map(\.id)
    }

    @Test func expressSummaryLineOrder() {
        let context = express { $0.historyCount = 2 }
        #expect(context.subpage == "Express")
        #expect(context.summaryLine == "Express · Highlights · Auto · captions off · 1 source · 2 earlier highlights")
        #expect(express { $0.sourceName = nil }.summaryLine == "Express · Highlights · Auto · captions off · no source")
        #expect(express { $0.footageKind = .qa }.summaryLine == "Express · Q&A · captions off · 1 source")
    }

    @Test func expressContextListsSettings() {
        let context = express {
            $0.settings.captions = true
            $0.settings.transition = "fade"
            $0.instructions = "Only the funny bits"
        }
        #expect(context.isOn("captions"))
        #expect(context.isOn("watermark"))
        #expect(context.isOff("nameTags"))
        #expect(context.value("transition") == "fade")
        #expect(context.value("instructions") == "Only the funny bits")
        #expect(express().value("transition") == nil)
        #expect(express().value("instructions") == nil)
    }

    @Test func expressCaptionsRule() {
        #expect(ids(express { $0.hasTranscript = true }).contains("express.captions.on"))
        #expect(!ids(express { $0.hasTranscript = false }).contains("express.captions.on"))
        #expect(!ids(express { $0.hasTranscript = true; $0.settings.captions = true }).contains("express.captions.on"))
        let row = WizardAssistant().suggestions(for: express { $0.hasTranscript = true })
            .first { $0.id == "express.captions.on" }
        #expect(row?.kind == .setting)
        #expect(row?.actionID == "express.set.captions.on")
    }

    @Test func expressLengthRule() {
        #expect(ids(express { $0.sourceSeconds = 1500 }).contains("express.length.shorter"))
        #expect(!ids(express { $0.sourceSeconds = 1100 }).contains("express.length.shorter"))
        #expect(!ids(express { $0.sourceSeconds = 1500; $0.length = .thirty }).contains("express.length.shorter"))
        #expect(!ids(express { $0.sourceSeconds = 1500; $0.footageKind = .qa }).contains("express.length.shorter"))
    }

    @Test func expressSafeAreaRule() {
        #expect(ids(express { $0.platforms = ["instagram"] }).contains("express.safearea.on"))
        #expect(!ids(express { $0.platforms = [] }).contains("express.safearea.on"))
        #expect(!ids(express { $0.platforms = ["instagram"]; $0.settings.safeAreaOnly = true }).contains("express.safearea.on"))
    }

    @Test func sourcesAndAnalysisRules() {
        #expect(ids(express { $0.sourceCount = 0; $0.sceneCount = 0 }).contains("wizard.sources.none"))
        let unanalyzed = WizardAssistant().suggestions(for: full { $0.sceneCount = 0 })
        #expect(unanalyzed.map(\.id).contains("wizard.analyze.first"))
        #expect(unanalyzed.first { $0.id == "wizard.analyze.first" }?.kind == .insight)
        #expect(unanalyzed.first { $0.id == "wizard.analyze.first" }?.actionID == nil)
        #expect(!ids(full { $0.sceneCount = 0 }).contains("wizard.sources.none"))
        #expect(ids(full()).isEmpty)
    }

    @Test func historyCompareRule() {
        #expect(ids(express { $0.historyCount = 2 }).contains("wizard.history.compare"))
        #expect(!ids(express { $0.historyCount = 1 }).contains("wizard.history.compare"))
        #expect(!ids(express { $0.historyCount = 3; $0.regeneratedCount = 1 }).contains("wizard.history.compare"))
        #expect(ids(full { $0.historyCount = 4 }).contains("wizard.history.compare"))
    }

    @Test func expressOnlyRulesStayQuietInFull() {
        let context = full { $0.instructions = "x" }
        #expect(context.subpage == "Full")
        #expect(context.isOn("useBRoll"))
        #expect(context.isOff("nameTags"))
        #expect(!ids(context).contains { $0.hasPrefix("express.") })
        #expect(context.summaryLine == "Full · Custom · Auto · Separate videos · 2 sources")
    }

    // MARK: - Review fixes: resolved page state, settings, bounds

    @Test func expressSettingsChangeTheFingerprint() {
        let base = express()
        let edits: [(String, (inout MiniWizardSettings) -> Void)] = [
            ("dub", { $0.dub = true; $0.dubLanguage = "es" }),
            ("music", { $0.music = true }),
            ("look", { $0.look = "vintage" }),
            ("captionStyle", { $0.captions = true; $0.captionStyleID = "style-1" }),
            ("captionLanguage", { $0.captions = true; $0.englishCaptions = true }),
            ("overlayTemplate", { $0.overlay = true; $0.overlayTemplate = "Lower third" }),
            ("broll", { $0.includeBRoll = true }),
            ("muteSourceAudio", { $0.muteSourceAudio = true }),
            ("quality", { $0.quality = .archival }),
        ]
        var seen: Set<String> = [base.fingerprint]
        for (key, edit) in edits {
            let context = express { edit(&$0.settings) }
            #expect(context.value(key) != nil, "\(key) is listed")
            #expect(seen.insert(context.fingerprint).inserted, "\(key) changes the fingerprint")
        }
        // Off or default fields stay out of the context.
        #expect(base.value("dub") == nil)
        #expect(base.value("look") == nil)
        #expect(express { $0.settings.captions = true; $0.settings.captionStyleID = "s"; $0.captionStyleName = "Bold" }
                    .value("captionStyle") == "Bold")
    }

    @Test func fullSettingsChangeTheFingerprint() {
        let base = full()
        let edits: [(String, (inout WizardAssistant.FullPresentation) -> Void)] = [
            ("captions", { $0.captions = true }),
            ("headlines", { $0.headlines = true }),
            ("dubLanguage", { $0.dubLanguage = "fr" }),
            ("captionLanguage", { $0.captionLanguage = "de" }),
            ("musicTrack", { $0.musicTrack = "Song.mp3" }),
            ("overlayStyle", { $0.overlayStyle = "bold" }),
            ("branding", { $0.branding = "Minimal" }),
            ("captionStyle", { $0.captions = true; $0.captionStyle = "Bold" }),
        ]
        var seen: Set<String> = [base.fingerprint]
        for (key, edit) in edits {
            let context = full { edit(&$0.presentation) }
            #expect(context.value(key) != nil, "\(key) is listed")
            #expect(seen.insert(context.fingerprint).inserted, "\(key) changes the fingerprint")
        }
        #expect(base.isOff("captions"))
        #expect(base.isOn("music"))
    }

    @Test func fullContextUsesTheResolvedSourceChoice() {
        let empty = full { $0.sourceSummary = "Choose Analyze batches"; $0.poolScenes = 0 }
        #expect(empty.value("sourceChoice") == "Choose Analyze batches")
        #expect(empty.int("pool.scenes") == 0)
        #expect(ids(empty).contains("wizard.sources.empty"))
        #expect(!ids(full { $0.poolScenes = 12 }).contains("wizard.sources.empty"))
        #expect(!ids(full()).contains("wizard.sources.empty"))
        #expect(full { $0.keptSelections = 2 }.int("kept") == 2)
    }

    @Test func savedBatchesFromOtherProjectsDoNotCount() {
        #expect(WizardAssistant.sourceSummary(limitToSelection: true, savedRunIDs: [1, 2, 9], projectRunIDs: [1, 2, 3],
                                              favoritesOnly: false) == "2 Analyze batches")
        // Restricted with nothing of this project chosen: the page's pool is empty, not "all footage".
        #expect(WizardAssistant.sourceSummary(limitToSelection: true, savedRunIDs: [9], projectRunIDs: [1],
                                              favoritesOnly: false) == "Choose Analyze batches")
        #expect(WizardAssistant.sourceSummary(limitToSelection: false, savedRunIDs: [9], projectRunIDs: [1],
                                              favoritesOnly: false) == "All analyzed scenes")
        #expect(WizardAssistant.sourceSummary(limitToSelection: false, savedRunIDs: [], projectRunIDs: [],
                                              favoritesOnly: true) == "Favorite scenes")
    }

    @Test func durationWhitelistMatchesTheForm() {
        let setting = WizardAssistant.fullSettings.first { $0.key == "targetDurationSeconds" }
        #expect(setting?.kind == .integer(WizardDefaults.customDurationRange))
        #expect(WizardDefaults.customDurationRange == 3...180)
        #expect(setting?.normalize(3) == "3")
        #expect(setting?.normalize(180) == "180")
        #expect(setting?.normalize(300) == nil)
        #expect(setting?.normalize(2) == nil)
        #expect(WizardDefaults.clampedCustomDuration(600) == 180)
        #expect(WizardDefaults.clampedCustomDuration(1) == 3)
    }

    @Test func applyFullClampsTheDuration() throws {
        let suite = "WizardAssistantTests.duration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        WizardAssistant.applyFull(["targetDurationSeconds": "500"], defaults: defaults)
        #expect(defaults.integer(forKey: WizardDefaults.customDurationKey) == 180)
        WizardAssistant.applyFull(["targetDurationSeconds": "3"], defaults: defaults)
        #expect(defaults.integer(forKey: WizardDefaults.customDurationKey) == 3)
        #expect(defaults.string(forKey: WizardDefaults.durationModeKey) == WizardDurationMode.custom.rawValue)
    }

    @Test func regenerateNoteParsing() {
        #expect(WizardAssistant.regenerateNote("Regenerate it with more jokes") == "more jokes")
        #expect(WizardAssistant.regenerateNote("regenerate with note: shorter intro") == "shorter intro")
        #expect(WizardAssistant.regenerateNote("Regenerate") == "")
        #expect(WizardAssistant.regenerateNote("redo this one: start at the punch") == "start at the punch")
        #expect(WizardAssistant.regenerateNote("Make a 30-second reel") == nil)
        #expect(WizardAssistant.regenerateNote("Find the regenerate button") == nil)
    }

    // MARK: - Store-backed: what the page published

    @MainActor
    private func makeStore() -> AppStore {
        let settings = AppSettings()
        let profile = Fixtures.brand(name: "WizardAssistantTests")
        let store = AppStore(settings: settings, profiles: [profile], active: profile, ai: AIService(config: settings.ai))
        store.diagnosticLogSink = { _, _ in }
        return store
    }

    @MainActor
    @Test func expressContextFollowsThePagesEffectiveFlow() throws {
        let suite = "WizardAssistantTests.express-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore()
        store.wizardMode = .express
        // Remembered Q&A, but the page shows Highlights for this ordinary video.
        defaults.set(MiniWizardFlow.FootageKind.qa.rawValue,
                     forKey: MiniWizardMemory.key(for: .footageKind, profileName: store.activeProfile.profileName))
        var page = WizardAssistant.ExpressPage()
        page.projectID = store.activeProjectID
        page.sourceName = "walk.mov"
        page.sourceSeconds = 1800
        page.footageKind = .highlights
        page.keptCount = 3
        page.settings.dub = true
        store.assistant.expressPage = page
        let snapshot = WizardAssistant().expressSnapshot(store: store, defaults: defaults)
        #expect(snapshot.footageKind == .highlights)
        #expect(snapshot.keptCount == 3)
        #expect(snapshot.settings.dub)
        let context = WizardAssistant.context(express: snapshot)
        #expect(context.value("footage") == "Highlights")
        // The shorter-length suggestion is no longer suppressed by the stale Q&A preference.
        #expect(WizardAssistant().suggestions(for: context).map(\.id).contains("express.length.shorter"))
        // A page published for another project is not used.
        page.projectID = 999
        store.assistant.expressPage = page
        #expect(WizardAssistant().expressSnapshot(store: store, defaults: defaults).footageKind == .qa)
    }

    @MainActor
    @Test func fullContextUsesThePagesKeptTakes() {
        let store = makeStore()
        store.wizardMode = .full
        var page = WizardAssistant.FullPage()
        page.projectID = store.activeProjectID
        page.sourceSummary = "Choose Analyze batches"
        page.poolScenes = 0
        page.keptTakes = 1
        page.presentation.captions = true
        store.assistant.fullPage = page
        let snapshot = WizardAssistant().fullSnapshot(store: store)
        #expect(snapshot.keptSelections == 1)
        #expect(snapshot.sourceSummary == "Choose Analyze batches")
        #expect(snapshot.poolScenes == 0)
        #expect(WizardAssistant.context(full: snapshot).isOn("captions"))
    }

    @MainActor
    @Test func wizardCommandsCarryTheirModesNamespace() throws {
        let store = makeStore()
        store.wizardMode = .full
        var full = WizardAssistant.FullPage()
        full.projectID = store.activeProjectID
        full.canGenerate = true
        store.assistant.fullPage = full
        let generate = try #require(WizardAssistant().actions(store: store).first { $0.id == "wizard.generate" })
        #expect(generate.isAvailable(store))
        _ = generate.run(store)
        let command = try #require(store.assistant.pendingCommand)
        #expect(command.belongs(to: "full."))
        #expect(!command.belongs(to: "express."))

        store.assistant.pendingCommand = nil
        store.wizardMode = .express
        let history = try #require(WizardAssistant().actions(store: store).first { $0.id == "wizard.history" })
        _ = history.run(store)
        #expect(store.assistant.pendingCommand?.belongs(to: "express.") == true)
        #expect(store.assistant.pendingCommand?.belongs(to: "full.") == false)
    }

    @MainActor
    @Test func generateAndRegenerateFollowTheExpressPage() throws {
        let store = makeStore()
        store.wizardMode = .express
        func action(_ id: String) throws -> AssistantAction {
            try #require(WizardAssistant().actions(store: store).first { $0.id == id })
        }
        // Not on screen yet: nothing to generate from, no candidate to regenerate.
        #expect(try !action("wizard.generate").isAvailable(store))
        #expect(try !action("wizard.regenerate").isAvailable(store))
        var page = WizardAssistant.ExpressPage()
        page.projectID = store.activeProjectID
        page.canGenerate = true
        page.selectedCandidate = "Highlight 2"
        store.assistant.expressPage = page
        #expect(try action("wizard.generate").isAvailable(store))
        #expect(try action("wizard.regenerate").isAvailable(store))
        // A typed "regenerate with …" goes to the selected candidate with its note.
        #expect(WizardAssistant().handle("Regenerate it with a stronger hook", store: store)
                == .handled("Sent Regenerate to Express with your note."))
        #expect(store.assistant.pendingCommand?.actionID == "wizard.regenerate")
        #expect(store.assistant.pendingCommand?.text == "a stronger hook")
        #expect(store.assistant.pendingCommand?.belongs(to: "express.") == true)
        page.selectedCandidate = nil
        store.assistant.expressPage = page
        if case .unavailable = WizardAssistant().handle("regenerate", store: store) {} else {
            Issue.record("Regenerate without a selected candidate must be refused")
        }
    }

    @Test func setActionIDs() {
        #expect(WizardAssistant.setActionID("captions", on: true, express: true) == "express.set.captions.on")
        #expect(WizardAssistant.setActionID("nameTags", on: false, express: false) == "full.set.nameTags.off")
    }
}
