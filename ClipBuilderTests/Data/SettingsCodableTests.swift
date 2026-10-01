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

    @Test("Existing Instagram settings default to Facebook without token dates")
    func legacyInstagram() throws {
        let json = #"{"instagram":{"connected_username":"peacegrappler","connected_ig_user_id":"ig-123","fetch_limit":24}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).instagram
        #expect(settings.connectedUsername == "peacegrappler")
        #expect(settings.connectedIGUserID == "ig-123")
        #expect(settings.fetchLimit == 24)
        #expect(settings.tokenFlavor == "facebook")
        #expect(settings.tokenExpiresAt == nil)
        #expect(settings.tokenRefreshedAt == nil)
    }

    @Test("Instagram token metadata round trips with snake-case keys")
    func instagramTokenMetadata() throws {
        var settings = InstagramSettings()
        settings.tokenFlavor = "instagram"
        settings.tokenRefreshedAt = Date(timeIntervalSince1970: 1_800_000_000)
        settings.tokenExpiresAt = settings.tokenRefreshedAt?.addingTimeInterval(60 * 86400)
        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["token_flavor"] as? String == "instagram")
        #expect(object["token_expires_at"] != nil)
        #expect(object["token_refreshed_at"] != nil)
        let decoded = try JSONDecoder().decode(InstagramSettings.self, from: data)
        #expect(decoded.tokenFlavor == "instagram")
        #expect(decoded.tokenExpiresAt == settings.tokenExpiresAt)
        #expect(decoded.tokenRefreshedAt == settings.tokenRefreshedAt)
    }
}
