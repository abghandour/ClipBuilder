import Foundation
import Testing
@testable import Clip_Builder

@Suite("Settings Codable")
struct SettingsCodableTests {
    @Test("older settings JSON receives current defaults")
    func olderShapeDefaults() throws {
        let data = Data(#"{"analysis_mode":"speech","transcribe_provider":"whisper","ai":{"tasks":{"wizard":"claude"}}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.analysisMode == "speech")
        #expect(settings.transcribeProvider == "apple")
        #expect(settings.theme == "default")
        #expect(settings.instagram.fetchLimit == 12)
        #expect(settings.transitions.xfadeDuration == 0.35)
        #expect(settings.ai.tasks["wizard"] == "claude")
        #expect(settings.ai.taskModels.isEmpty)

        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.analysisMode == settings.analysisMode)
        #expect(roundTrip.instagram.fetchLimit == settings.instagram.fetchLimit)
        #expect(roundTrip.transitions.xfadeDuration == settings.transitions.xfadeDuration)
    }

    @Test("transition duration is clamped when decoded")
    func transitionClamp() throws {
        let low = try JSONDecoder().decode(TransitionSettings.self, from: Data(#"{"xfade_duration":0}"#.utf8))
        let high = try JSONDecoder().decode(TransitionSettings.self, from: Data(#"{"xfade_duration":9}"#.utf8))
        #expect(low.xfadeDuration == 0.1)
        #expect(high.xfadeDuration == 1)
    }
}
