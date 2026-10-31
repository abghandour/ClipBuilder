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
}
