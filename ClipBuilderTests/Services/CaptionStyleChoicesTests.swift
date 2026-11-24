import Foundation
import Testing
@testable import Clip_Builder

@Suite("Caption style choices")
struct CaptionStyleChoicesTests {
    @Test("the chooser offers the fallback, the profile's looks and every library look")
    func offersEverything() {
        let own = NamedCaptionStyle(name: "Mine", style: CaptionStyle())
        let groups = CaptionStyleChoices.groups(saved: [own], fallbackName: "Profile default", fallbackStyle: CaptionStyle())
        #expect(groups.first?.title == "This profile")
        #expect(groups.first?.choices.map(\.name) == ["Profile default", "Mine"])
        let library = groups.dropFirst().flatMap(\.choices).map(\.name)
        #expect(Set(library) == Set(CaptionPresets.styles.map(\.name)))
        #expect(library.contains("PG Preferred"))
    }

    @Test("a library look the profile already holds unchanged is listed once")
    func untouchedCopyHidesTheLibraryEntry() throws {
        let preset = try #require(CaptionPresets.styles.first { $0.name == "Boxed" })
        var edited = preset
        edited.style.strokeWidth = 9
        let all = CaptionStyleChoices.groups(saved: [preset], fallbackName: "d", fallbackStyle: CaptionStyle())
        #expect(!all.dropFirst().flatMap(\.choices).contains { $0.name == "Boxed" })
        #expect(CaptionStyleChoices.existing(preset, in: [preset])?.id == preset.id)
        let changed = CaptionStyleChoices.groups(saved: [edited], fallbackName: "d", fallbackStyle: CaptionStyle())
        #expect(changed.dropFirst().flatMap(\.choices).contains { $0.name == "Boxed" })
    }

    @Test("search filters by name and drops empty groups")
    func search() {
        let groups = CaptionStyleChoices.groups(saved: [], fallbackName: "Profile default",
                                                fallbackStyle: CaptionStyle(), search: "pg pref")
        #expect(groups.map(\.title) == ["Library · Creator"])
        #expect(groups.first?.choices.map(\.id) == ["library:PG Preferred"])
    }
}
