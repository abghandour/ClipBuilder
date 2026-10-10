import Foundation

/// Creative policy shared by a profile. Legacy app settings are only a
/// fallback until the profile is explicitly edited or safely seeded on save.
nonisolated struct ProfileEditingDefaults: Codable, Sendable, Hashable {
    var transitions = TransitionSettings()
    var podcast = PodcastEditingPolicy()
    var footage = FootageDefaults()

    enum CodingKeys: String, CodingKey {
        case transitions, podcast, footage
    }

    init() {}

    init(seedingFrom settings: AppSettings) {
        transitions = settings.transitions
        podcast = PodcastEditingPolicy(settings.podcast)
        footage = FootageDefaults(settings)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transitions = try container.decodeIfPresent(TransitionSettings.self, forKey: .transitions) ?? TransitionSettings()
        podcast = try container.decodeIfPresent(PodcastEditingPolicy.self, forKey: .podcast) ?? PodcastEditingPolicy()
        footage = try container.decodeIfPresent(FootageDefaults.self, forKey: .footage) ?? FootageDefaults()
    }
}
