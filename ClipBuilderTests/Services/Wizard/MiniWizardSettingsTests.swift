import Foundation
import Testing
@testable import Clip_Builder

@Suite("Mini Wizard settings")
struct MiniWizardSettingsTests {
    @Test func controlsMapToPresentationOptionsAndPreserveOtherDefaults() {
        var base = WizardOptions().step2
        var render = RenderSettings()
        render.customCRF = 17
        base.renderSettings = render
        base.framingCamera = "gentle"
        base.includeMiddleBumper = true
        base.includeHeadline = true
        base.includeOutro = true
        base.useMusic = true
        for enabled in [false, true] {
            for quality in [EncodeQuality.archival, .balanced, .compact] {
                for preset in RenderPreset.allCases where preset != .custom {
                    var settings = MiniWizardSettings()
                    settings.quality = quality
                    settings.preset = preset
                    settings.captions = enabled
                    settings.englishCaptions = enabled
                    settings.introVideo = enabled
                    settings.outroVideo = enabled
                    settings.watermark = enabled
                    settings.nameTags = enabled
                    let result = settings.step2Options(base: base)
                    #expect(result.renderSettings?.quality == quality && result.renderSettings?.preset == preset)
                    #expect(result.renderSettings?.customCRF == 17 && result.framingCamera == "gentle")
                    #expect(result.addCaptions == enabled && result.captionLanguage == (enabled ? "en" : nil))
                    #expect(result.includeIntroBumper == enabled && result.includeOutroBumper == enabled)
                    #expect(result.includeWatermark == enabled && result.enableTextOverlays == enabled)
                    #expect(result.nameTagsOnly == true)
                    #expect(result.includeHeadline == false && result.includeOutro == false && result.useMusic == false)
                    #expect(result.includeMiddleBumper == true)
                }
            }
        }
    }

    @Test func audioChoicesMapToMusicAndMuteOnlyForFightFootage() throws {
        var settings = MiniWizardSettings()
        var base = WizardStep2Options()
        base.useMusic = true
        base.musicFolder = "Fights"
        base.musicTrack = "old.mp3"
        // Off by default, and Express never inherits the full Wizard's folder or track.
        var result = settings.step2Options(base: base)
        #expect(result.useMusic == false && result.muteSource == false && result.musicTrack == nil && result.musicFolder == nil)
        settings.music = true
        settings.muteSourceAudio = true
        result = settings.step2Options(base: base)
        #expect(result.useMusic == true && result.muteSource == true && result.musicTrack == nil, "random leaves the track to the render")
        settings.musicTrack = " Intros/hype.mp3 "
        #expect(settings.step2Options(base: base).musicTrack == "Intros/hype.mp3")
        settings.music = false
        #expect(settings.step2Options(base: base).musicTrack == nil && settings.step2Options(base: base).muteSource == true)
        // Hidden for talk footage: a remembered answer cannot mute a podcast.
        var fight = Fixtures.video()
        fight.videoType = VideoType.fight.rawValue
        var podcast = Fixtures.video()
        podcast.videoType = VideoType.podcast.rawValue
        settings.music = true
        let onFight = settings.effective(for: MiniWizardFlow(video: fight), introAvailable: false, outroAvailable: false)
        #expect(onFight.music && onFight.muteSourceAudio)
        let onPodcast = settings.effective(for: MiniWizardFlow(video: podcast), introAvailable: false, outroAvailable: false)
        #expect(!onPodcast.music && !onPodcast.muteSourceAudio)
        // Old JSON without the keys decodes to the defaults.
        let decoded = try JSONDecoder().decode(MiniWizardSettings.self, from: Data("{}".utf8))
        #expect(!decoded.music && !decoded.muteSourceAudio && decoded.musicTrack == nil)
    }

    @Test func overlayMapsToAFixedOverlayOnlyWhenOnAndNamed() throws {
        var settings = MiniWizardSettings()
        settings.overlayTemplate = "Lower third"
        settings.overlayStart = 3
        settings.overlayDuration = 4
        let off = settings.step2Options(base: WizardStep2Options())
        #expect(off.fixedOverlayTemplate == nil && off.fixedOverlayStart == nil && off.fixedOverlayDuration == nil)
        #expect(settings.overlayName == nil)
        settings.overlay = true
        settings.overlayTexts = ["Hook", ""]
        let on = settings.step2Options(base: WizardStep2Options())
        #expect(on.fixedOverlayTemplate == "Lower third" && on.fixedOverlayStart == 3 && on.fixedOverlayDuration == 4)
        #expect(on.fixedOverlayTexts == ["Hook", ""] && off.fixedOverlayTexts == nil)
        #expect(settings.overlayName == "Lower third")
        settings.overlayDuration = nil
        settings.overlayStart = -2
        let whole = settings.step2Options(base: WizardStep2Options())
        #expect(whole.fixedOverlayStart == 0 && whole.fixedOverlayDuration == nil)
        settings.overlayTemplate = "  "
        #expect(settings.step2Options(base: WizardStep2Options()).fixedOverlayTemplate == nil)
        let merged = WizardOptions.merge(step1: WizardStep1Options(), step2: on)
        #expect(merged.fixedOverlayTemplate == "Lower third" && merged.step2.fixedOverlayDuration == 4)
        let decoded = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(merged))
        #expect(decoded.fixedOverlayStart == 3 && decoded.fixedOverlayTexts == ["Hook", ""] && decoded.fixedOverlayDuration == 4)
        var full = merged
        full.introBumperPath = "/a.mp4"
        full.outroBumperPath = "/b.mp4"
        var picked = MiniWizardSettings()
        picked.introVideo = true
        picked.introBumper = "Intros/open.mp4"
        #expect(picked.step2Options(base: WizardStep2Options()).introBumperPath == nil, "library paths resolve at generate time")
        #expect(BumperAsset.libraryPath(of: "/lib/bumpers/Intros/open.mp4", root: URL(fileURLWithPath: "/lib/bumpers")) == "Intros/open.mp4")
        #expect(BumperAsset.libraryPath(of: "/elsewhere/open.mp4", root: URL(fileURLWithPath: "/lib/bumpers")) == "open.mp4")
        full.watermarkOverlayTemplate = "Main"
        full.watermarkOpacity = 0.3
        let again = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(full))
        #expect(again.introBumperPath == "/a.mp4" && again.outroBumperPath == "/b.mp4")
        #expect(again.watermarkOverlayTemplate == "Main" && again.watermarkOpacity == 0.3)
        #expect(MiniWizardFlow().settingsSummary(settings).contains("overlay") == false)
        settings.overlayTemplate = "Lower third"
        #expect(MiniWizardFlow().settingsSummary(settings).contains("overlay Lower third"))
    }

    @Test func watermarkOverlayOnlyMapsWhileTheWatermarkIsOn() {
        var settings = MiniWizardSettings()
        settings.watermark = true
        settings.watermarkOverlay = "Main"
        #expect(settings.step2Options(base: WizardStep2Options()).watermarkOverlayTemplate == "Main")
        #expect(MiniWizardFlow().settingsSummary(settings).contains("watermark Main"))
        settings.watermark = false
        #expect(settings.step2Options(base: WizardStep2Options()).watermarkOverlayTemplate == nil)
        settings.watermark = true
        settings.watermarkOverlay = " "
        #expect(settings.step2Options(base: WizardStep2Options()).watermarkOverlayTemplate == nil)
        #expect(MiniWizardFlow().settingsSummary(settings).hasSuffix("watermark"))
        #expect(settings.effectiveWatermarkOpacity == BrandRenderer.logoWatermarkOpacity)
        settings.watermarkOverlay = "Main"
        #expect(settings.effectiveWatermarkOpacity == WizardFixedOverlay.watermarkOpacity)
        settings.watermarkOpacity = 0.3
        #expect(settings.effectiveWatermarkOpacity == 0.3)
        #expect(settings.step2Options(base: WizardStep2Options()).watermarkOpacity == 0.3)
        settings.watermark = false
        #expect(settings.step2Options(base: WizardStep2Options()).watermarkOpacity == nil)
    }

    @Test func transitionDefaultsToRandomAndMapsToTheChoice() {
        var settings = MiniWizardSettings()
        #expect(settings.transition == "random")
        #expect(settings.step2Options(base: WizardStep2Options()).transitionChoice == "random")
        settings.transition = "fadeblack"
        #expect(settings.step2Options(base: WizardStep2Options()).transitionChoice == "fadeblack")
        settings.transition = " "
        #expect(settings.step2Options(base: WizardStep2Options()).transitionChoice == "random")
        let merged = WizardOptions.merge(step1: WizardStep1Options(), step2: MiniWizardSettings().step2Options(base: WizardStep2Options()))
        #expect(merged.transitionChoice == "random")
        #expect((try? JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(merged)))?.transitionChoice == "random")
        #expect(WizardOptions().transitionChoice == nil)
    }

    @Test func lookMapsToThePresetOnlyWhenChosen() throws {
        var settings = MiniWizardSettings()
        #expect(settings.look == "" && settings.lookName == nil)
        #expect(settings.step2Options(base: WizardStep2Options()).lookPreset == nil)
        settings.look = "vintage"
        #expect(settings.lookName == "vintage")
        let merged = WizardOptions.merge(step1: WizardStep1Options(), step2: settings.step2Options(base: WizardStep2Options()))
        #expect(merged.lookPreset == "vintage")
        #expect(WizardEngine.lookEffect(for: merged) == EffectSpec(preset: "vintage"))
        #expect((try? JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(merged)))?.lookPreset == "vintage")
        settings.look = "none"
        #expect(settings.lookName == nil && settings.step2Options(base: WizardStep2Options()).lookPreset == nil)
        var unknown = merged
        unknown.lookPreset = "no-such-look"
        #expect(WizardEngine.lookEffect(for: unknown) == nil)
        // Older presets and options without the key still decode.
        let legacy = try JSONDecoder().decode(MiniWizardSettings.self, from: Data(#"{"transition":"fade"}"#.utf8))
        #expect(legacy.look == "" && legacy.transition == "fade")
        let roundTrip = try JSONDecoder().decode(MiniWizardSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.look == "none")
        #expect(WizardOptions().lookPreset == nil)
    }

    @Test func everyCameraFocusMapsLikeTheFullWizard() {
        var settings = MiniWizardSettings()
        for kind in CropRecipe.Kind.allCases {
            settings.cameraFocus = kind.rawValue
            let mapped = settings.step2Options(base: WizardStep2Options())
            #expect(mapped.highlightFraming == kind && mapped.podcastFraming == .followSpeaker)
        }
        settings.cameraFocus = WizardCameraFocus.original
        let original = settings.step2Options(base: WizardStep2Options())
        #expect(original.highlightFraming == nil && original.podcastFraming == .original)
        settings.cameraFocus = ""
        let automatic = settings.step2Options(base: original)
        #expect(automatic.highlightFraming == nil && automatic.podcastFraming == .followSpeaker)
    }

    @Test func hiddenChoicesAndUnavailableBumpersCannotAffectAnotherSource() {
        var settings = MiniWizardSettings()
        settings.cameraFocus = WizardCameraFocus.original
        settings.nameTags = true
        settings.captions = true
        settings.englishCaptions = true
        settings.introVideo = true
        settings.outroVideo = true
        let ordinary = settings.effective(for: MiniWizardFlow(video: Fixtures.video(), captionsEnabled: true),
            introAvailable: false, outroAvailable: false)
        #expect(ordinary.cameraFocus.isEmpty && !ordinary.nameTags && !ordinary.englishCaptions)
        #expect(!ordinary.introVideo && !ordinary.outroVideo)
        let podcast = MiniWizardFlow(video: Fixtures.video(), hasPodcastExchangeScenes: true,
                                    captionsEnabled: true, transcriptLanguage: "pt")
        #expect(settings.effective(for: podcast, introAvailable: true, outroAvailable: true) == settings)
    }

    @Test func rememberingUnchangedExpressAnswersWritesNoKey() throws {
        let suite = "MiniWizardSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = Fixtures.brand()
        var settings = MiniWizardSettings.remembered(profile: profile, defaults: defaults)
        #expect(settings.remember(profileName: profile.profileName, defaults: defaults))
        #expect(!settings.remember(profileName: profile.profileName, defaults: defaults))
        settings.captions.toggle()
        #expect(settings.remember(profileName: profile.profileName, defaults: defaults))
        #expect(!settings.remember(profileName: profile.profileName, defaults: defaults))
        #expect(MiniWizardSettings.remembered(profile: profile, defaults: defaults) == settings)
    }

    @Test func remembersEachProfileAndUsesProfileRenderDefaults() throws {
        let suite = "MiniWizardSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var profile = Fixtures.brand()
        profile.profileName = "First"
        profile.defaultRenderSettings = RenderSettings(preset: .landscape4K, quality: .archival)
        defaults.set(WizardBrandingMode.none.rawValue, forKey: WizardDefaults.brandingModeKey)
        var settings = MiniWizardSettings.remembered(profile: profile, defaults: defaults)
        #expect(settings.quality == .archival && settings.preset == .landscape4K && settings.watermark)
        settings.quality = .compact
        settings.preset = .square1080
        settings.cameraFocus = WizardCameraFocus.original
        settings.captions = true
        settings.englishCaptions = true
        settings.introVideo = true
        settings.outroVideo = true
        settings.nameTags = true
        settings.watermark = true
        settings.outputMode = .oneReel
        settings.remember(profileName: profile.profileName, defaults: defaults)
        #expect(MiniWizardSettings.remembered(profile: profile, defaults: defaults) == settings)
        profile.profileName = "Second"
        #expect(MiniWizardSettings.remembered(profile: profile, defaults: defaults).quality == .archival)
        #expect(!MiniWizardSettings.remembered(profile: profile, defaults: defaults).captions)
        profile.defaultRenderSettings = RenderSettings(preset: .custom, quality: .custom)
        let supported = MiniWizardSettings.remembered(profile: profile, defaults: defaults)
        #expect(supported.quality == .balanced && supported.preset == .portrait1080)
    }

    @Test func optionalNameTagsFlagSurvivesMergeAndOldJSONStillDecodes() throws {
        #expect(try JSONDecoder().decode(WizardStep2Options.self, from: Data("{}".utf8)).nameTagsOnly == nil)
        var base = WizardOptions()
        base.captionLanguage = "es"
        let mapped = MiniWizardSettings().step2Options(base: base.step2)
        let merged = WizardOptions.merge(step1: base.step1, step2: mapped, base: base)
        #expect(merged.captionLanguage == nil && merged.nameTagsOnly == true && merged.step2.nameTagsOnly == true)
        let decoded = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(merged))
        #expect(decoded.nameTagsOnly == true)
    }
}

extension MiniWizardSettingsTests {
    @Test func transcriptLanguageComesFromOriginalStoredSegments() async throws {
        let temp = try TempDatabase()
        let video = try await temp.seedVideo()
        #expect(try await temp.database.originalTranscriptLanguage(videoID: video) == nil)
        let rows = [TranscriptSegment(start: 0, end: 4, text: "Question", words: nil)]
        try await temp.database.replaceTranscripts(videoID: video, transcriptionKey: "test-transcription", language: "en", isTranslation: true,
            segments: rows, provider: nil, model: nil)
        #expect(try await temp.database.originalTranscriptLanguage(videoID: video) == nil)
        try await temp.database.replaceTranscripts(videoID: video, transcriptionKey: "test-transcription", language: "pt", isTranslation: false,
            segments: rows, provider: nil, model: nil)
        #expect(try await temp.database.originalTranscriptLanguage(videoID: video) == "pt")
    }

    @Test func combinedSelectionKeepsOriginalsOutOfTheRestorableBatch() async throws {
        let temp = try TempDatabase()
        let db = temp.database
        let video = try await temp.seedVideo()
        let project = try await db.createProject(profileName: "Mini", name: "Mini", videoIDs: [video])
        let scenes = try await db.fetchScenes(projectID: project).sorted { $0.startTime < $1.startTime }
        let scene = try #require(scenes.first)
        var options = WizardOptions().step1
        options.formatPreset = "podcast"
        options.targetDurationSeconds = 10
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: scene.startTime, end: scene.endTime)])
        let first = try await db.recordWizardTake(projectID: project, options: options, plan: plan, miniBatch: "mini")
        let second = try await db.recordWizardTake(projectID: project, options: options, plan: plan, miniBatch: "mini")
        let combined = try await db.recordMiniCombinedTake(projectID: project, miniBatch: "mini", name: "Renamed question",
            takes: [second, first], options: options)
        let selection = try #require(try await db.wizardSelection(id: combined.selectionID))
        #expect(selection.name == "Renamed question" && selection.recipe == "podcast" && selection.miniBatch == "mini:combined")
        #expect(selection.step1Options.targetDurationSeconds == nil)
        #expect(combined.ordinal == 1 && combined.provenance == nil && combined.plan.provenance == nil)
        #expect(combined.plan.clips.count == 2 && combined.plan.transitions == ["cut"])
        #expect(try await db.fetchWizardSelections(projectID: project, miniBatch: "mini").count == 2)
        #expect(try await db.fetchWizardSelectionTakes(selectionID: first.selectionID).count == 1)
        #expect(try await db.fetchWizardSelectionTakes(selectionID: second.selectionID).count == 1)
    }
}

extension MiniWizardSettingsTests {
    @Test func captionChoicesMapAndStayWithTheirProfile() throws {
        let suite = "CaptionChoices.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for position in [nil, "bottom", "middle", "top"] as [String?] {
            var settings = MiniWizardSettings()
            settings.captions = true
            settings.captionPosition = position
            settings.captionStyleID = UUID().uuidString
            settings.remember(profileName: "First", defaults: defaults)
            let restored = MiniWizardSettings.remembered(profile: Fixtures.brand(name: "First"), defaults: defaults)
            #expect(restored.captionPosition == position && restored.captionStyleID == settings.captionStyleID)
            let options = restored.step2Options(base: WizardStep2Options())
            #expect(options.captionPosition == position && options.captionStyleID == settings.captionStyleID)
            let other = MiniWizardSettings.remembered(profile: Fixtures.brand(name: "Second"), defaults: defaults)
            #expect(other.captionPosition == nil && other.captionStyleID == nil)
            let full = WizardCaptionChoices(captionPosition: position, captionStyleID: settings.captionStyleID)
            full.save(profileName: "First", defaults: defaults)
            #expect(WizardCaptionChoices.load(profileName: "First", defaults: defaults) == full)
            #expect(WizardCaptionChoices.load(profileName: "Second", defaults: defaults) == WizardCaptionChoices())
        }
    }
}

extension MiniWizardSettingsTests {
    @Test func persistentNameTagChoicesMapAndStayWithTheirProfile() throws {
        let suite = "NameTagChoices.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = MiniWizardSettings()
        settings.nameTags = true
        settings.nameTagContent = "nameAndRole"
        settings.nameTagStyle = "Guest look"
        settings.nameTagPosition = "topTrailing"
        settings.remember(profileName: "First", defaults: defaults)
        let restored = MiniWizardSettings.remembered(profile: Fixtures.brand(name: "First"), defaults: defaults)
        #expect(restored == settings)
        let other = MiniWizardSettings.remembered(profile: Fixtures.brand(name: "Second"), defaults: defaults)
        #expect(!other.nameTags && other.nameTagContent == nil && other.nameTagStyle == nil && other.nameTagPosition == nil)
        let step = restored.step2Options(base: WizardStep2Options())
        #expect(step.nameTags == true && step.nameTagsOnly == true)
        #expect(step.nameTagContent == "nameAndRole" && step.nameTagStyle == "Guest look" && step.nameTagPosition == "topTrailing")
        let options = WizardOptions.merge(step1: WizardStep1Options(), step2: step)
        #expect(options.usesNameTags && options.step2.nameTagStyle == "Guest look")
    }
}

extension MiniWizardSettingsTests {
    @Test func tagStyleSelectionMapsToStepTwoAndOldTemplateIsIgnored() throws {
        let named = NamedTagStyle(name: "Guest", style: TagStyle())
        var profile = Fixtures.brand()
        profile.tagStyles = [named]
        var settings = MiniWizardSettings()
        settings.nameTags = true
        settings.nameTagStyle = "Old overlay"
        settings.nameTagStyleID = named.id.uuidString
        let step = settings.step2Options(base: WizardStep2Options())
        #expect(step.nameTagStyleID == named.id.uuidString)
        settings.nameTagStyleID = nil
        let legacy = settings.step2Options(base: step)
        #expect(legacy.nameTagStyleID == nil)
        #expect(profile.tagStyle(id: legacy.nameTagStyleID) == TagStyle())
        profile.tagStyles = []
        #expect(profile.tagStyle(id: step.nameTagStyleID) == TagStyle())
    }
}

extension MiniWizardSettingsTests {
    @Test func safeAreaSettingsRoundTripAndRememberPerProfile() throws {
        let old = try JSONDecoder().decode(MiniWizardSettings.self, from: Data("{}".utf8))
        #expect(!old.safeAreaOnly && old.safeAreaPlatforms == nil)
        var settings = old
        settings.safeAreaOnly = true
        settings.safeAreaPlatforms = ["instagram", "tiktok"]
        #expect(try JSONDecoder().decode(MiniWizardSettings.self, from: JSONEncoder().encode(settings)) == settings)
        let suite = "safe-area-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = Fixtures.brand()
        #expect(!MiniWizardSettings.remembered(profile: profile, defaults: defaults).safeAreaOnly)
        settings.remember(profileName: profile.profileName, defaults: defaults)
        let remembered = MiniWizardSettings.remembered(profile: profile, defaults: defaults)
        #expect(remembered.safeAreaOnly)
        #expect(remembered.safeAreaPlatforms == ["instagram", "tiktok"])
        let step = settings.step2Options(base: WizardStep2Options())
        #expect(step.safeAreaOnly == true && step.safeAreaPlatforms == [.instagram, .tiktok])
        settings.safeAreaPlatforms = []
        #expect(settings.step2Options(base: WizardStep2Options()).safeAreaPlatforms == nil)
    }
}

extension MiniWizardSettingsTests {
    @Test func dubbingDecodesOldPresetsAndRoundTripsWithoutWizardDefaults() throws {
        let old = try JSONDecoder().decode(MiniWizardSettings.self, from: Data("{}".utf8))
        #expect(!old.dub && old.dubLanguage == nil)
        var settings = MiniWizardSettings()
        settings.dub = true; settings.dubLanguage = "pt-BR"
        let decoded = try JSONDecoder().decode(MiniWizardSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        let suite = "DubMini-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fr-FR", forKey: "wizard.dubLanguage")
        let profile = Fixtures.brand(name: "Dub")
        #expect(!MiniWizardSettings.remembered(profile: profile, defaults: defaults).dub)
        settings.remember(profileName: profile.profileName, defaults: defaults)
        let remembered = MiniWizardSettings.remembered(profile: profile, defaults: defaults)
        #expect(remembered.dub && remembered.dubLanguage == "pt-BR")
        #expect(defaults.string(forKey: "wizard.dubLanguage") == "fr-FR")
        #expect(MiniWizardMemory.key(for: .dub, profileName: "Dub") == "mini.Dub.dub")
        #expect(MiniWizardMemory.key(for: .dubLanguage, profileName: "Dub") == "mini.Dub.dubLanguage")
        var base = WizardOptions(); base.dubLanguage = "fr-FR"
        #expect(settings.previewOptions(profile: profile, base: base).dubLanguage == "pt-BR")
        settings.dub = false
        #expect(settings.previewOptions(profile: profile, base: base).dubLanguage == nil)
    }

    @Test func conversationalFootageRetainsDubWhileSuppressingMusicAndMute() {
        var video = Fixtures.video(); video.videoType = VideoType.interview.rawValue
        var settings = MiniWizardSettings()
        settings.dub = true; settings.dubLanguage = "en-US"
        settings.music = true; settings.muteSourceAudio = true
        let effective = settings.effective(for: MiniWizardFlow(video: video), introAvailable: false, outroAvailable: false)
        #expect(effective.dub && effective.dubLanguage == "en-US")
        #expect(!effective.music && !effective.muteSourceAudio)
    }

    @Test func draggedOverlayPositionMapsOnlyWithAnOverlayAndRoundTripsThroughMemory() throws {
        var settings = MiniWizardSettings()
        settings.overlay = true
        settings.overlayTemplate = "Lower Third"
        settings.overlayPosition = CustomPosition(x: 0.3, y: 0.7).string
        let profile = Fixtures.brand()
        #expect(settings.previewOptions(profile: profile).fixedOverlayPosition == "custom:0.3000,0.7000")
        settings.overlayPosition = "somewhere"
        #expect(settings.previewOptions(profile: profile).fixedOverlayPosition == nil, "only custom strings travel")
        settings.overlayPosition = CustomPosition(x: 0.3, y: 0.7).string
        settings.overlay = false
        #expect(settings.previewOptions(profile: profile).fixedOverlayPosition == nil)
        let suite = "MiniWizardSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.remember(profileName: profile.profileName, defaults: defaults)
        #expect(MiniWizardSettings.remembered(profile: profile, defaults: defaults).overlayPosition == settings.overlayPosition)
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(MiniWizardSettings.self, from: encoded).overlayPosition == settings.overlayPosition)
    }

    @Test func defaultsFollowTheProfileCanvasQualityAndDubLanguage() {
        var profile = Fixtures.brand()
        profile.defaultRenderSettings.quality = .compact
        profile.defaultRenderSettings.preset = .landscape1080
        let plain = MiniWizardSettings.defaults(profile: profile)
        #expect(plain.quality == .compact && plain.preset == .landscape1080)
        #expect(!plain.captions && !plain.nameTags && plain.captionPosition == nil && plain.overlayPosition == nil)
        #expect(!plain.dub && plain.dubLanguage == nil)
        // Custom render settings fall back to the shipped choices.
        profile.defaultRenderSettings.quality = .custom
        profile.defaultRenderSettings.preset = .custom
        let fallback = MiniWizardSettings.defaults(profile: profile)
        #expect(fallback.quality == .balanced && fallback.preset == .portrait1080)
        // Reset equals what a profile with no memory would start with.
        let suite = "MiniWizardSettingsTests.defaults.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suite) {
            defer { defaults.removePersistentDomain(forName: suite) }
            #expect(MiniWizardSettings.remembered(profile: profile, defaults: defaults) == fallback)
        }
    }

    @Test func zoomMovesMapsToTheOptionsAndRoundTripsThroughMemoryAndPresets() throws {
        var settings = MiniWizardSettings()
        settings.cameraFocus = CropRecipe.Kind.interview.rawValue
        settings.interviewZoomMoves = true
        let profile = Fixtures.brand()
        #expect(settings.previewOptions(profile: profile).interviewZoomMoves == true)
        #expect(MiniWizardSettings().previewOptions(profile: profile).interviewZoomMoves == false)
        let suite = "MiniWizardSettingsTests.zoomMoves.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.remember(profileName: profile.profileName, defaults: defaults)
        #expect(MiniWizardSettings.remembered(profile: profile, defaults: defaults).interviewZoomMoves)
        let fields = WizardPresetBridge.wizardFields(from: settings)
        #expect(fields["interviewZoomMoves"]?.bool == true)
        #expect(WizardPresetBridge.miniSettings(from: fields).interviewZoomMoves)
    }
}

extension MiniWizardSettingsTests {
    @Test(arguments: InterviewPunchIn.allCases)
    func interviewChoicesRoundTripThroughEverySettingsBridge(punchIn: InterviewPunchIn) throws {
        let profile = Fixtures.brand()
        var settings = MiniWizardSettings()
        settings.cameraFocus = CropRecipe.Kind.interview.rawValue
        settings.interviewCuts = true
        settings.interviewPunchIn = punchIn.rawValue
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(MiniWizardSettings.self, from: encoded) == settings)
        let options = settings.previewOptions(profile: profile)
        #expect(options.interviewCuts == true && options.interviewPunchIn == punchIn.rawValue)
        let decoded = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.interviewCuts == true && decoded.interviewPunchIn == punchIn.rawValue)
        let step = try JSONDecoder().decode(WizardStep2Options.self, from: JSONEncoder().encode(options.step2))
        let merged = WizardOptions.merge(step1: options.step1, step2: step, base: WizardOptions())
        #expect(merged.interviewCuts == true && merged.interviewPunchIn == punchIn.rawValue)
        let fields = WizardPresetBridge.wizardFields(from: settings)
        #expect(fields["interviewCuts"]?.bool == true && fields["interviewPunchIn"]?.string == punchIn.rawValue)
        let restored = WizardPresetBridge.miniSettings(from: fields)
        #expect(restored.interviewCuts == true && restored.interviewPunchIn == punchIn.rawValue)
        let suite = "MiniWizardSettingsTests.punchIn.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.remember(profileName: profile.profileName, defaults: defaults)
        let remembered = MiniWizardSettings.remembered(profile: profile, defaults: defaults)
        #expect(remembered.interviewCuts == true && remembered.interviewPunchIn == punchIn.rawValue)
        let other = MiniWizardSettings.remembered(profile: BrandProfile(name: "Other"), defaults: defaults)
        #expect(!other.resolvedInterviewCuts && other.resolvedInterviewPunchIn == "vip")
        settings.interviewCuts = false
        let smooth = WizardPresetBridge.miniSettings(from: WizardPresetBridge.wizardFields(from: settings), base: restored)
        #expect(smooth.interviewCuts == false)
    }

    @Test func oldSettingsKeepSmoothVIPDefaults() throws {
        let mini = try JSONDecoder().decode(MiniWizardSettings.self, from: Data("{}".utf8))
        #expect(!mini.resolvedInterviewCuts && mini.resolvedInterviewPunchIn == "vip")
        let preset = WizardPresetBridge.miniSettings(from: WizardPresetBridge.wizardFields(from: mini))
        #expect(preset == mini)
        let options = try JSONDecoder().decode(WizardOptions.self, from: Data("{}".utf8))
        #expect(options.interviewCuts == nil && options.interviewPunchIn == nil)
        let step = try JSONDecoder().decode(WizardStep2Options.self, from: Data("{}".utf8))
        #expect(step.interviewCuts == nil && step.interviewPunchIn == nil)
        var unknown = mini
        unknown.interviewPunchIn = "future-choice"
        #expect(unknown.previewOptions(profile: Fixtures.brand()).interviewPunchIn == "vip")
        #expect(CropRecipe(kind: .interview).interviewCuts == false)
        #expect(CropRecipe(kind: .interview).interviewPunchIn == .vip)
    }
}

extension MiniWizardSettingsTests {
    @Test func speakerPositionsSurviveLegacyDecodePresetsAndEffectiveOptions() throws {
        let old = try JSONDecoder().decode(MiniWizardSettings.self, from: Data("{}".utf8))
        #expect(old.speakerCaptionPositions == nil)
        var settings = old
        settings.captions = true
        settings.speakerCaptionPositions = ["speaker1": "top", "speaker2": "custom:0.2500,0.6000"]
        let decoded = try JSONDecoder().decode(MiniWizardSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        let preset = MiniWizardPreset(name: "Interview", savedAt: Date(), settings: settings)
        let restored = try JSONDecoder().decode(MiniWizardPreset.self, from: JSONEncoder().encode(preset))
        #expect(restored.settings.speakerCaptionPositions == settings.speakerCaptionPositions)
        let effective = settings.effective(for: MiniWizardFlow(video: Fixtures.video()), introAvailable: false, outroAvailable: false)
        #expect(effective.previewOptions(profile: Fixtures.brand()).speakerCaptionPositions == settings.speakerCaptionPositions)
        let fields = WizardPresetBridge.wizardFields(from: settings)
        #expect(WizardPresetBridge.miniSettings(from: fields).speakerCaptionPositions == settings.speakerCaptionPositions)
        #expect(WizardPresetBridge.miniSettings(from: ["speakerCaptionPositions": .null], base: settings).speakerCaptionPositions == nil)
    }

    @Test func speakerPositionsAreRememberedPerProfileAndCanBeCleared() throws {
        let suite = "caption-position-memory-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = MiniWizardSettings()
        settings.speakerCaptionPositions = ["speaker1": "middle", "speaker2": "top"]
        settings.remember(profileName: "First", defaults: defaults)
        #expect(MiniWizardSettings.remembered(profile: Fixtures.brand(name: "First"), defaults: defaults)
            .speakerCaptionPositions == settings.speakerCaptionPositions)
        #expect(MiniWizardSettings.remembered(profile: Fixtures.brand(name: "Second"), defaults: defaults)
            .speakerCaptionPositions == nil)
        settings.speakerCaptionPositions = nil
        settings.remember(profileName: "First", defaults: defaults)
        #expect(MiniWizardSettings.remembered(profile: Fixtures.brand(name: "First"), defaults: defaults)
            .speakerCaptionPositions == nil)
    }
}

extension MiniWizardSettingsTests {
    @Test func oldOutputModesDecodeButExpressAlwaysProducesOneReel() throws {
        for mode in MiniWizardFlow.OutputMode.allCases {
            let json = Data("{\"outputMode\":\"\(mode.rawValue)\"}".utf8)
            var settings = try JSONDecoder().decode(MiniWizardSettings.self, from: json)
            #expect(settings.outputMode == mode)
            #expect(settings.includeBRoll == nil && !settings.includesBRoll)
            let flow = MiniWizardFlow(outputMode: settings.outputMode)
            #expect(flow.outputCount(keptCount: 4) == 1)
            #expect(flow.generateButtonTitle(keptCount: 4) == "Generate Video")
            #expect(!flow.settingsSummary(settings).contains("reel"))
            settings.didEditBRoll()
            #expect(settings.includesBRoll && settings.step2Options(base: .init()).useBRoll == true)
            settings.includesBRoll = false
            #expect(settings.step2Options(base: .init()).useBRoll == false)
            settings.didEditBRoll()
            #expect(settings.includesBRoll)
            let restored = try JSONDecoder().decode(MiniWizardSettings.self, from: JSONEncoder().encode(settings))
            #expect(restored.includeBRoll == true)
        }
    }

    @Test func packageListsOnlyEnabledManualBRoll() {
        var plan = Fixtures.plan()
        plan.clips[0].brollCuts = [.init(start: 1, end: 2, sceneID: 2, sceneOffset: 0, reason: "word", origin: .user)]
        let candidate = MiniWizardCandidate(selection: .init(id: 1, projectID: 1, name: "Kept", recipe: "podcast", step1Options: .init()),
            take: .init(id: 1, selectionID: 1, ordinal: 1, plan: plan, sceneIDs: [1]))
        let flow = MiniWizardFlow(video: Fixtures.video(), hasPodcastExchangeScenes: true)
        var settings = MiniWizardSettings()
        settings.didEditBRoll()
        let included = flow.runSummaryCard(candidates: [candidate], exchangeCount: 0, settings: settings)
        #expect(included.sections.first { $0.title == "Package" }?.items == ["B-roll (1)"])
        settings.includesBRoll = false
        let excluded = flow.runSummaryCard(candidates: [candidate], exchangeCount: 0, settings: settings)
        #expect(excluded.sections.first { $0.title == "Package" }?.items.isEmpty == true)
        #expect(candidate.take.plan.clips[0].brollCuts?.count == 1)
    }
}
