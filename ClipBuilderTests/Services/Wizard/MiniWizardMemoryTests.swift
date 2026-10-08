import Foundation
import Testing
@testable import Clip_Builder

@Suite("Mini Wizard memory")
struct MiniWizardMemoryTests {
    @Test func everyAnswerHasAStableDistinctProfileKey() {
        let names: Set<String> = ["videoPath", "footageKind", "length", "quality", "preset", "cameraFocus",
            "captions", "englishCaptions", "captionPosition", "captionStyleID", "introVideo", "outroVideo", "nameTags", "nameTagContent", "nameTagStyle", "nameTagStyleID", "nameTagPosition", "watermark", "outputMode"]
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
        first.captions = true
        first.englishCaptions = true
        first.introVideo = true
        first.outroVideo = true
        first.nameTags = true
        first.nameTagStyleID = UUID().uuidString
        first.watermark = false
        first.outputMode = .oneReel
        let second = MiniWizardSettings()
        first.remember(profileName: "First", defaults: defaults)
        second.remember(profileName: "Second", defaults: defaults)
        for name in ["First", "Second"] {
            defaults.set("/\(name).mp4", forKey: MiniWizardMemory.key(for: .videoPath, profileName: name))
            defaults.set(MiniWizardFlow.FootageKind.qa.rawValue,
                         forKey: MiniWizardMemory.key(for: .footageKind, profileName: name))
            defaults.set(MiniWizardFlow.Length.fifteen.rawValue,
                         forKey: MiniWizardMemory.key(for: .length, profileName: name))
            for field in MiniWizardMemory.Field.allCases where ![.captionPosition, .captionStyleID, .nameTagContent, .nameTagStyle, .nameTagStyleID, .nameTagPosition].contains(field) {
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
