import Foundation
import Testing
@testable import Clip_Builder

@Suite("Mini Wizard memory")
struct MiniWizardMemoryTests {
    @Test func everyAnswerHasAStableDistinctProfileKey() {
        let names: Set<String> = ["videoPath", "footageKind", "length", "quality", "preset", "cameraFocus", "interviewZoom",
            "interviewZoomMoves", "captions", "englishCaptions", "captionPosition", "captionStyleID", "introVideo", "outroVideo", "nameTags", "nameTagContent", "nameTagStyle", "nameTagStyleID", "nameTagPosition", "watermark", "outputMode",
            "overlay", "overlayTemplate", "overlayStart", "overlayDuration", "overlayTexts", "overlayPosition", "introBumper", "outroBumper", "watermarkOverlay", "watermarkOpacity", "transition", "look",
                                  "muteSourceAudio", "music", "musicTrack", "settingsTab", "safeAreaOnly", "safeAreaPlatforms",
                                  "dub", "dubLanguage"]
        #expect(Set(MiniWizardMemory.Field.allCases.map(\.rawValue)) == names)
        for profile in ["First", "First.Second", "Profile with spaces", "عربي"] {
            let keys = MiniWizardMemory.Field.allCases.map { MiniWizardMemory.key(for: $0, profileName: profile) }
            #expect(Set(keys).count == names.count)
            for field in MiniWizardMemory.Field.allCases {
                let key = MiniWizardMemory.key(for: field, profileName: profile)
                #expect(key == "mini.\(profile).\(field.rawValue)")
                #expect(MiniWizardMemory.field(forKey: key, profileName: profile) == field)
                #expect(MiniWizardMemory.field(forKey: key, profileName: "Other") == nil)
            }
        }
        #expect(MiniWizardMemory.field(forKey: "mini.First.Second.length", profileName: "First") == nil)
        #expect(MiniWizardMemory.field(forKey: "mini.First.futureField", profileName: "First") == nil)
        #expect(MiniWizardMemory.field(forKey: "wizard.length", profileName: "First") == nil)
    }

    @Test func keptExchangesStartEmptyAndAreRememberedPerProfileAndVideo() throws {
        let name = "QAKept-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(MiniWizardMemory.qaKept(profileName: "A", videoID: 7, defaults: defaults).isEmpty)
        MiniWizardMemory.saveQAKept([3, 1], profileName: "A", videoID: 7, defaults: defaults)
        #expect(MiniWizardMemory.qaKept(profileName: "A", videoID: 7, defaults: defaults) == [1, 3])
        #expect(MiniWizardMemory.qaKept(profileName: "A", videoID: 8, defaults: defaults).isEmpty)
        #expect(MiniWizardMemory.qaKept(profileName: "B", videoID: 7, defaults: defaults).isEmpty)
        MiniWizardMemory.saveQAKept([], profileName: "A", videoID: 7, defaults: defaults)
        #expect(defaults.object(forKey: MiniWizardMemory.qaKeptKey(profileName: "A", videoID: 7)) == nil)
    }

    @Test func rememberedVideoMustStillBeAnalyzedAndInTheCurrentProjectList() throws {
        var video = Fixtures.video()
        video.analyzedAt = "2026-10-03"
        #expect(MiniWizardMemory.validatedVideoPath(try #require(video.path), videos: [video]) == video.path)
        #expect(MiniWizardMemory.validatedVideoPath(try #require(video.path), videos: []) == "")
        #expect(MiniWizardMemory.validatedVideoPath("/removed.mp4", videos: [video]) == "")
        #expect(MiniWizardMemory.validatedVideoPath("", videos: [video]) == "")
        var other = video
        other.path = "/another.mp4"
        #expect(MiniWizardMemory.validatedVideoPath(try #require(video.path), videos: [other]) == "")
        video.analyzedAt = nil
        #expect(MiniWizardMemory.validatedVideoPath(try #require(video.path), videos: [video, other]) == "")
    }

    @Test func allSettingsRestoreAcrossProfilesUsingTheSameKeyCatalog() throws {
        let suite = "MiniWizardMemoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var first = MiniWizardSettings()
        first.quality = .compact
        first.preset = .landscape4K
        first.cameraFocus = WizardCameraFocus.original
        first.interviewZoomMoves = true
        first.captions = true
        first.englishCaptions = true
        first.introVideo = true
        first.outroVideo = true
        first.introBumper = "Intros/open.mp4"
        first.outroBumper = "close.mp4"
        first.nameTags = true
        first.nameTagStyleID = UUID().uuidString
        first.watermark = false
        first.watermarkOverlay = "Main"
        first.watermarkOpacity = 0.25
        first.overlay = true
        first.overlayTemplate = "Lower third"
        first.overlayStart = 2.5
        first.overlayDuration = 4
        first.overlayTexts = ["Watch the full fight", ""]
        first.overlayPosition = "custom:0.2000,0.9000"
        first.outputMode = .oneReel
        first.transition = "fade"
        first.muteSourceAudio = true
        first.music = true
        first.musicTrack = "Intros/hype.mp3"
        first.dub = true
        first.dubLanguage = "pt-BR"
        let second = MiniWizardSettings()
        first.remember(profileName: "First", defaults: defaults)
        second.remember(profileName: "Second", defaults: defaults)
        for name in ["First", "Second"] {
            defaults.set("/\(name).mp4", forKey: MiniWizardMemory.key(for: .videoPath, profileName: name))
            defaults.set(MiniWizardFlow.FootageKind.qa.rawValue,
                         forKey: MiniWizardMemory.key(for: .footageKind, profileName: name))
            defaults.set(MiniWizardFlow.Length.fifteen.rawValue,
                         forKey: MiniWizardMemory.key(for: .length, profileName: name))
            for field in MiniWizardMemory.Field.allCases where ![.captionPosition, .captionStyleID, .nameTagContent, .nameTagStyle, .nameTagStyleID, .nameTagPosition, .overlayTemplate, .overlayDuration, .overlayPosition, .introBumper, .outroBumper, .watermarkOverlay, .watermarkOpacity, .musicTrack, .settingsTab, .safeAreaPlatforms, .dubLanguage].contains(field) {
                #expect(defaults.object(forKey: MiniWizardMemory.key(for: field, profileName: name)) != nil)
            }
        }
        for name in ["First", "Second", "First"] {
            #expect(MiniWizardSettings.remembered(profile: Fixtures.brand(name: name), defaults: defaults)
                == (name == "First" ? first : second))
            #expect(defaults.string(forKey: MiniWizardMemory.key(for: .videoPath, profileName: name)) == "/\(name).mp4")
            #expect(defaults.string(forKey: MiniWizardMemory.key(for: .footageKind, profileName: name)) == "qa")
            #expect(defaults.string(forKey: MiniWizardMemory.key(for: .length, profileName: name)) == "15")
        }
    }
}
