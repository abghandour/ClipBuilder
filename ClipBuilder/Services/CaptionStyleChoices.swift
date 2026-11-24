import Foundation

/// What the caption style chooser offers: the run's fallback, the profile's
/// own looks, and every library look the profile does not already hold.
nonisolated enum CaptionStyleChoices {
    enum Source: Hashable, Sendable {
        /// No choice: the profile default, or the run's style for a speaker.
        case fallback
        case profile(UUID)
        /// A library look by name. Choosing it adds a copy to the profile.
        case library(String)
    }

    struct Choice: Identifiable, Hashable, Sendable {
        var source: Source
        var name: String
        var style: CaptionStyle
        var id: String {
            switch source {
            case .fallback: "fallback"
            case .profile(let id): id.uuidString
            case .library(let name): "library:" + name
            }
        }
    }

    struct Group: Identifiable, Hashable, Sendable {
        var title: String
        var choices: [Choice]
        var id: String { title }
    }

    static func groups(saved: [NamedCaptionStyle], fallbackName: String, fallbackStyle: CaptionStyle,
                       library: [NamedCaptionStyle] = CaptionPresets.styles, search: String = "") -> [Group] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ name: String) -> Bool { needle.isEmpty || name.localizedCaseInsensitiveContains(needle) }
        var groups: [Group] = []
        let own = [Choice(source: .fallback, name: fallbackName, style: fallbackStyle)]
            + saved.map { Choice(source: .profile($0.id), name: $0.name, style: $0.style) }
        groups.append(Group(title: "This profile", choices: own.filter { matches($0.name) }))
        for family in CaptionPresets.Family.allCases {
            let members = library.filter { $0.family == family && existing($0, in: saved) == nil }
            groups.append(Group(title: "Library · " + family.rawValue,
                                choices: members.filter { matches($0.name) }
                                    .map { Choice(source: .library($0.name), name: $0.name, style: $0.style) }))
        }
        return groups.filter { !$0.choices.isEmpty }
    }

    /// The profile's untouched copy of a library look, if it has one.
    static func existing(_ preset: NamedCaptionStyle, in saved: [NamedCaptionStyle]) -> NamedCaptionStyle? {
        saved.first { $0.name == preset.name && $0.style == preset.style }
    }
}
