import Foundation
import Testing
@testable import Clip_Builder

struct VoicePickerRulesTests {
    private func voice(_ id: String, _ name: String, cloned: Bool = false, at: TimeInterval? = nil,
                       gender: DubVoiceGender = .male) -> DubSynthesizer.Voice {
        .init(identifier: ElevenLabsVoices.identifierPrefix + id, language: "en", name: name, quality: 3, gender: gender,
              isCloned: cloned, createdAt: at.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func splitsNameFromDescriptionAndDropsTheClonedMark() {
        #expect(VoicePickerRules.split("Adam - Dominant, Firm") == ("Adam", "Dominant, Firm"))
        #expect(VoicePickerRules.split("Helmut - German Epic Trailer Voice  (cloned)") == ("Helmut", "German Epic Trailer Voice"))
        #expect(VoicePickerRules.split("Marcello Spinelli (cloned)") == ("Marcello Spinelli", ""))
        #expect(VoicePickerRules.split("Samantha") == ("Samantha", ""))
    }

    @Test func clonesAndStockVoicesSitInSeparateSections() {
        let sections = VoicePickerRules.sections(
            voices: [voice("will", "Will - Relaxed Optimist"), voice("old", "Marcello Spinelli (cloned)", cloned: true, at: 100),
                     voice("adam", "Adam - Dominant, Firm"), voice("lib", "Helmut - Epic (cloned)", cloned: true),
                     voice("new", "Marcello Spinelli (cloned)", cloned: true, at: 300),
                     voice("kept", "Marcello Spinelli (cloned)", cloned: true, at: 200),
                     voice("alice", "alice pereira (cloned)", cloned: true, at: 50)],
            clones: ["marcello": "kept"], people: [("marcello", "Marcello Spinelli"), ("alice", "Alice Pereira")])
        #expect(sections.stock.map(\.title) == ["Adam", "Will"])
        // People first; the remembered take leads its person, then newest first; library clones last.
        #expect(sections.cloned.map(\.id) == ["alice", "kept", "new", "old", "lib"].map { ElevenLabsVoices.identifierPrefix + $0 })
        #expect(sections.cloned.map(\.personKey) == ["alice", "marcello", "marcello", "marcello", nil])
        #expect(sections.cloned.map(\.isRememberedClone) == [false, true, false, false, false])
        #expect(sections.choice(ElevenLabsVoices.identifierPrefix + "adam")?.detail == "Dominant, Firm")
        #expect(sections.choice("elevenlabs:gone") == nil)
    }

    @Test func macVoicesShowTheirQualityAndNeverAClone() {
        let sections = VoicePickerRules.sections(
            voices: [.init(identifier: "com.apple.voice.premium.en-US.Ava", language: "en-US", name: "Ava", quality: 3)],
            clones: ["ava": "com.apple.voice.premium.en-US.Ava"], people: [("ava", "Ava")])
        #expect(sections.cloned.isEmpty)
        #expect(sections.stock.first?.detail == "Premium")
    }

    @Test func cloneCaptionShowsTheYearOnlyWhenItIsNotThisYear() {
        let utc = TimeZone(identifier: "UTC")!, us = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_795_000_000)   // 2026-11-18
        var choice = VoiceChoice(id: "a", title: "Ana", detail: "", isCloned: true,
                                 clonedAt: Date(timeIntervalSince1970: 1_795_000_000 - 86_400), face: VoiceFace.make(name: "Ana", gender: .female))
        let recent = VoicePickerRules.cloneCaption(choice, now: now, locale: us, timeZone: utc)
        #expect(recent.hasPrefix("Cloned Nov 17") && !recent.contains("2026"))
        choice.isRememberedClone = true
        choice.clonedAt = Date(timeIntervalSince1970: 1_700_000_000)   // 2023
        let old = VoicePickerRules.cloneCaption(choice, now: now, locale: us, timeZone: utc)
        #expect(old.hasPrefix("Shared · Nov 14") && old.contains("2023"))
        choice.clonedAt = nil
        #expect(VoicePickerRules.cloneCaption(choice) == "Shared with your team")
    }

    @Test func aNameAlwaysDrawsTheSameFaceAndKnownVoicesAreCast() {
        #expect(VoiceFace.make(name: "Zoltan", gender: .male) == VoiceFace.make(name: "Zoltan", gender: .male))
        #expect(VoiceFace.make(name: "Harry", gender: .male).accessory == .helmet)
        #expect(VoiceFace.make(name: "Priya", gender: .female).facialHair == .none)
        for name in ["Zoltan", "Marek", "Priya", "Ingrid", ""] {
            let face = VoiceFace.make(name: name, gender: .unknown)
            #expect(face.skin < VoiceFace.skinCount && face.hairColor < VoiceFace.hairColorCount && face.background < VoiceFace.backgroundCount)
        }
    }

    @Test func arrowsWalkTheTwoColumnGridAndCrossSections() {
        // Cloned: c1 c2 / c3      Stock: s1 s2 / s3 s4 / s5
        var sections = VoicePickerRules.Sections()
        let face = VoiceFace.make(name: "x", gender: .unknown)
        sections.cloned = ["c1", "c2", "c3"].map { VoiceChoice(id: $0, title: $0, detail: "", isCloned: true, face: face) }
        sections.stock = ["s1", "s2", "s3", "s4", "s5"].map { VoiceChoice(id: $0, title: $0, detail: "", face: face) }
        func go(_ move: VoicePickerRules.Move, _ id: String?) -> String? { VoicePickerRules.move(move, from: id, in: sections) }
        #expect(go(.down, nil) == "c1")
        #expect(go(.down, "c1") == "c3")
        #expect(go(.down, "c2") == "c3")       // short last row
        #expect(go(.down, "c3") == "s1")       // into Stock, same column
        #expect(go(.up, "s2") == "c3")         // Cloned's last row has no second column
        #expect(go(.up, "s1") == "c3")
        #expect(go(.up, "c3") == "c1")
        #expect(go(.up, "c1") == nil)
        #expect(go(.down, "s4") == "s5")
        #expect(go(.down, "s5") == nil)
        #expect(go(.right, "c3") == "s1")
        #expect(go(.left, "s1") == "c3")
        #expect(go(.left, "c1") == nil)
        #expect(go(.right, "s5") == nil)
        #expect(go(.down, "gone") == "c1")
        #expect(VoicePickerRules.move(.down, from: nil, in: .init()) == nil)
    }

    @Test func typingJumpsToTheFirstNameWithThatPrefix() {
        let sections = VoicePickerRules.sections(
            voices: [voice("will", "Will - Relaxed Optimist"), voice("bill", "Bill - Wise"), voice("brian", "Brian - Deep"),
                     voice("ana", "Ána (cloned)", cloned: true)],
            clones: [:], people: [])
        #expect(VoicePickerRules.match(typed: "b", in: sections) == "elevenlabs:bill")
        #expect(VoicePickerRules.match(typed: "BR", in: sections) == "elevenlabs:brian")
        #expect(VoicePickerRules.match(typed: "an", in: sections) == "elevenlabs:ana")
        #expect(VoicePickerRules.match(typed: "zz", in: sections) == nil)
        #expect(VoicePickerRules.match(typed: "", in: sections) == nil)
    }
}
