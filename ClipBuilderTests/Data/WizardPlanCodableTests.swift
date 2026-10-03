import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard plan Codable")
struct WizardPlanCodableTests {
    @Test func fullPlanRoundTripsEditorialAndLegacyPresentationFields() throws {
        var clip = Fixtures.planClip()
        clip.textOverlay = "The answer"
        clip.overlayStyle = "minimal"
        clip.overlayAnimation = "fade"
        clip.overlayKicker = "Guest"
        clip.overlayAccent = "#abc"
        clip.overlayPlacement = "bottom"
        clip.overlayCase = "as_written"
        clip.reason = "Keep end for the payoff"
        clip.speed = 0.5
        clip.replay = true
        clip.layout = "Split"
        clip.screenCrop = "Split/Left"
        clip.areaClips = [WizardPlanAreaClip(area: "Right", sceneID: 2, start: 4, end: 8)]
        clip.speakerIntroductions = [TextOverlayItem()]
        clip.leftSpeakerName = "Host"
        clip.rightSpeakerName = "Guest"
        var plan = Fixtures.plan(clips: [clip], transitions: ["fade"])
        plan.provenance = AIProvenance(provider: "fixture", model: "test", task: "wizard")
        plan.framing = .grid
        plan.headline = "A complete answer"
        plan.introTitle = "Listen"
        plan.fileName = "the-answer"
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(plan)
        let decoded = try JSONDecoder().decode(WizardPlan.self, from: data)
        #expect(try encoder.encode(decoded) == data)
        #expect(decoded.clips.first?.areaClips.first?.sceneID == 2)
        #expect(decoded.clips.first?.speakerIntroductions.count == 1)
    }

    @Test func missingOptionalEditorialAndStyleFieldsDecode() throws {
        let json = """
        {"targetDuration":4,"rationale":"old plan","musicVolume":3,"transitions":[],
         "clips":[{"sceneID":1,"start":0,"end":4,"speed":1,"replay":false,
                   "areaClips":[],"speakerIntroductions":[]}]}
        """
        let plan = try JSONDecoder().decode(WizardPlan.self, from: Data(json.utf8))
        #expect(plan.footage == nil)
        #expect(plan.framing == nil && plan.provenance == nil && plan.musicName == nil)
        #expect(plan.clips.first?.reason == nil && plan.clips.first?.overlayStyle == nil)
    }
}
