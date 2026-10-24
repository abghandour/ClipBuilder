import Foundation
import Testing
@testable import Clip_Builder

struct CaptionSpeakerStylesTests {
    @Test func personChoicesResolveAgainstTheRunAndDropDeletedOrEqualStyles() {
        var profile = Fixtures.brand()
        var runStyle = CaptionStyle()
        runStyle.color = "#00ff00"
        var personStyle = runStyle
        personStyle.color = "#ff0000"
        let run = NamedCaptionStyle(name: "Run", style: runStyle)
        let person = NamedCaptionStyle(name: "Person", style: personStyle)
        let duplicate = NamedCaptionStyle(name: "Same as run", style: runStyle)
        profile.captionStyles = [run, person, duplicate]
        profile.personCaptionStyles = ["ana": person.id.uuidString, "bob": run.id.uuidString,
            "same": duplicate.id.uuidString, "deleted": UUID().uuidString, "invalid": "not-a-uuid"]

        #expect(profile.captionStyle(forPerson: "ana", runStyleID: run.id.uuidString) == personStyle)
        for key in ["bob", "same", "deleted", "invalid", "unset"] {
            #expect(profile.captionStyle(forPerson: key, runStyleID: run.id.uuidString) == runStyle)
        }
        #expect(profile.speakerCaptionStyles(runStyleID: run.id.uuidString) == ["ana": personStyle])
        #expect(profile.captionStyle(forPerson: "unset", runStyleID: nil) == profile.captions)
        #expect(profile.captionStyle(forPerson: "deleted", runStyleID: "missing") == profile.captions)
        profile.personCaptionStyles = nil
        #expect(profile.speakerCaptionStyles(runStyleID: run.id.uuidString).isEmpty)
    }

    @Test func profileMappingRoundTripsAndOldJSONDecodes() throws {
        var profile = Fixtures.brand()
        let named = NamedCaptionStyle(name: "Speaker", style: CaptionStyle())
        profile.captionStyles = [named]
        profile.personCaptionStyles = ["ana": named.id.uuidString]
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(BrandProfile.self, from: data) == profile)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["person_caption_styles"] as? [String: String] == profile.personCaptionStyles)
        json.removeValue(forKey: "person_caption_styles")
        let legacy = try JSONDecoder().decode(BrandProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.personCaptionStyles == nil)
        #expect(legacy.captionStyles == profile.captionStyles)
        #expect(legacy.captionStyle(forPerson: "ana", runStyleID: nil) == profile.captions)
    }
}
