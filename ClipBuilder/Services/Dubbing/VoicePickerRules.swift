import Foundation

/// One row in the voice picker: a clone (shown with its person and date) or a
/// stock voice (shown with a drawn face).
nonisolated struct VoiceChoice: Identifiable, Equatable, Sendable {
    /// The voice identifier, which is what dub settings store.
    var id: String
    /// "Adam", "Marcello Spinelli".
    var title: String
    /// "Dominant, Firm", "Premium", or empty.
    var detail: String
    var isCloned = false
    var clonedAt: Date?
    /// The person this clone was made from, when the profile knows them.
    var personKey: String?
    /// The clone the profile remembers (and shares with the team) for that person.
    var isRememberedClone = false
    var face: VoiceFace
}

nonisolated enum VoicePickerRules {
    struct Sections: Equatable, Sendable {
        var cloned: [VoiceChoice] = []
        var stock: [VoiceChoice] = []

        func choice(_ id: String) -> VoiceChoice? {
            cloned.first { $0.id == id } ?? stock.first { $0.id == id }
        }
    }

    /// - Parameters:
    ///   - clones: person key to ElevenLabs voice id, from the profile.
    ///   - people: person key and display name, to find whose voice an
    ///     unremembered clone is (an older clone of the same person).
    static func sections(voices: [DubSynthesizer.Voice], clones: [String: String],
                         people: [(key: String, name: String)]) -> Sections {
        let personByVoice = Dictionary(clones.map { (ElevenLabsVoices.identifierPrefix + $0.value, $0.key) },
                                       uniquingKeysWith: { first, _ in first })
        let personByName = Dictionary(people.map { (folded($0.name), $0.key) }, uniquingKeysWith: { first, _ in first })
        var sections = Sections()
        for voice in voices {
            let parts = split(voice.name)
            let face = VoiceFace.make(name: parts.title, gender: voice.gender)
            if voice.isCloned {
                let remembered = personByVoice[voice.identifier]
                sections.cloned.append(VoiceChoice(
                    id: voice.identifier, title: parts.title, detail: parts.detail, isCloned: true,
                    clonedAt: voice.createdAt, personKey: remembered ?? personByName[folded(parts.title)],
                    isRememberedClone: remembered != nil, face: face))
            } else {
                let detail = parts.detail.isEmpty && !ElevenLabsVoices.isElevenLabs(voice.identifier)
                    ? voice.qualityLabel ?? "" : parts.detail
                sections.stock.append(VoiceChoice(id: voice.identifier, title: parts.title, detail: detail, face: face))
            }
        }
        // People's clones first, a person's takes together with the remembered
        // one on top and then newest first; library clones follow by name.
        sections.cloned.sort { a, b in
            if (a.personKey != nil) != (b.personKey != nil) { return a.personKey != nil }
            let nameOrder = a.title.localizedCaseInsensitiveCompare(b.title)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            if a.isRememberedClone != b.isRememberedClone { return a.isRememberedClone }
            if a.clonedAt != b.clonedAt { return (a.clonedAt ?? .distantPast) > (b.clonedAt ?? .distantPast) }
            return a.id < b.id
        }
        sections.stock.sort { a, b in
            let nameOrder = a.title.localizedCaseInsensitiveCompare(b.title)
            return nameOrder == .orderedSame ? a.id < b.id : nameOrder == .orderedAscending
        }
        return sections
    }

    /// "Adam - Dominant, Firm" is a name and a description; "(cloned)" is said
    /// by the section the voice sits in.
    static func split(_ name: String) -> (title: String, detail: String) {
        var name = name.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix("(cloned)") {
            name = String(name.dropLast("(cloned)".count)).trimmingCharacters(in: .whitespaces)
        }
        for separator in [" - ", " – ", " — "] {
            if let range = name.range(of: separator) {
                let title = name[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let detail = name[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return (title, detail) }
            }
        }
        return (name, "")
    }

    /// The second line of a clone's row. The time tells apart two takes of one
    /// person made the same day; the year shows only once it is not this year.
    static func cloneCaption(_ choice: VoiceChoice, now: Date = Date(), locale: Locale = .current,
                             timeZone: TimeZone = .current) -> String {
        guard let date = choice.clonedAt else {
            if choice.isRememberedClone { return "Shared with your team" }
            return choice.detail.isEmpty ? "Cloned voice" : choice.detail
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var style = Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day().hour().minute()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return (choice.isRememberedClone ? "Shared · " : "Cloned ") + date.formatted(style)
    }

    enum Move: Sendable { case up, down, left, right }

    /// Where an arrow key lands in the picker, which lays each section out
    /// row by row in `columns` columns, Cloned above Stock. Left and right
    /// walk the reading order; up and down keep the column where they can and
    /// cross into the neighbouring section at its edge. Nil means stay put.
    static func move(_ move: Move, from id: String?, in sections: Sections, columns: Int = 2) -> String? {
        let groups = [sections.cloned, sections.stock].filter { !$0.isEmpty }.map { $0.map(\.id) }
        let all = groups.flatMap { $0 }
        guard let id, let flat = all.firstIndex(of: id),
              let group = groups.firstIndex(where: { $0.contains(id) }),
              let index = groups[group].firstIndex(of: id) else { return all.first }
        let ids = groups[group], column = index % columns
        switch move {
        case .left: return flat > 0 ? all[flat - 1] : nil
        case .right: return flat + 1 < all.count ? all[flat + 1] : nil
        case .down:
            if index + columns < ids.count { return ids[index + columns] }
            // A short last row: drop to its last voice.
            if index / columns < (ids.count - 1) / columns { return ids[ids.count - 1] }
            guard group + 1 < groups.count else { return nil }
            let next = groups[group + 1]
            return next[min(column, next.count - 1)]
        case .up:
            if index >= columns { return ids[index - columns] }
            guard group > 0 else { return nil }
            let previous = groups[group - 1]
            let lastRow = (previous.count - 1) / columns * columns
            return previous[min(lastRow + column, previous.count - 1)]
        }
    }

    /// Type-to-select: the first voice, in reading order, whose name starts with what was typed.
    static func match(typed: String, in sections: Sections) -> String? {
        let typed = folded(typed)
        guard !typed.isEmpty else { return nil }
        return (sections.cloned + sections.stock).first { folded($0.title).hasPrefix(typed) }?.id
    }

    private static func folded(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// What a stock voice's drawn face looks like. The same name always gives the
/// same face, on every Mac, so a voice is recognizable by its picture.
nonisolated struct VoiceFace: Equatable, Sendable {
    enum Hair: Int, CaseIterable, Sendable { case short, sidePart, quiff, curly, buzz, bald, long, bob, bun, ponytail }
    enum FacialHair: Int, CaseIterable, Sendable { case none, beard, moustache, stubble }
    enum Accessory: Int, CaseIterable, Sendable {
        case none, glasses, sunglasses, headphones, headset, beanie, cap, helmet, earrings
    }
    enum Mouth: Int, CaseIterable, Sendable { case smile, grin, neutral, smirk }
    enum Brows: Int, CaseIterable, Sendable { case soft, raised, stern }

    /// Indexes into the renderer's palettes.
    var skin: Int
    var hairColor: Int
    var background: Int
    var hair: Hair
    var facialHair: FacialHair = .none
    var accessory: Accessory = .none
    var mouth: Mouth = .smile
    var brows: Brows = .soft

    static let skinCount = 6, hairColorCount = 7, backgroundCount = 8

    static func make(name: String, gender: DubVoiceGender) -> VoiceFace {
        let key = name.lowercased().split(separator: " ").first.map(String.init) ?? ""
        if let known = known[key] { return known }
        // FNV-1a: stable across launches and machines, unlike Hasher.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        func pick(_ count: Int) -> Int {
            defer { hash = (hash >> 7) | (hash << 57) }
            return Int(hash % UInt64(count))
        }
        let maleHair: [Hair] = [.short, .sidePart, .quiff, .curly, .buzz, .bald]
        let femaleHair: [Hair] = [.long, .bob, .bun, .ponytail, .curly, .sidePart]
        let hairStyles = gender == .male ? maleHair : gender == .female ? femaleHair : Hair.allCases
        let facial: [FacialHair] = gender == .male ? [.none, .none, .beard, .moustache, .stubble] : [.none]
        let accessories: [Accessory] = gender == .female
            ? [.none, .none, .glasses, .earrings, .headphones, .sunglasses]
            : [.none, .none, .glasses, .headphones, .beanie, .cap, .sunglasses]
        return VoiceFace(
            skin: pick(skinCount), hairColor: pick(hairColorCount), background: pick(backgroundCount),
            hair: hairStyles[pick(hairStyles.count)], facialHair: facial[pick(facial.count)],
            accessory: accessories[pick(accessories.count)],
            mouth: Mouth.allCases[pick(Mouth.allCases.count)], brows: Brows.allCases[pick(Brows.allCases.count)])
    }

    /// Hand-drawn casts for the voices ElevenLabs ships, so each picture hints
    /// at the voice's character ("Fierce Warrior", "Steady Broadcaster").
    /// Hair colours: 0 black, 1 dark brown, 2 brown, 3 auburn, 4 blond, 5 grey, 6 white.
    static let known: [String: VoiceFace] = [
        "adam": .init(skin: 3, hairColor: 0, background: 0, hair: .buzz, facialHair: .stubble, mouth: .neutral, brows: .stern),
        "bill": .init(skin: 1, hairColor: 6, background: 5, hair: .sidePart, facialHair: .moustache, accessory: .glasses),
        "brian": .init(skin: 4, hairColor: 0, background: 3, hair: .short, facialHair: .beard, mouth: .smile),
        "callum": .init(skin: 0, hairColor: 3, background: 2, hair: .curly, accessory: .beanie, mouth: .smirk, brows: .raised),
        "charlie": .init(skin: 1, hairColor: 4, background: 1, hair: .quiff, mouth: .grin, brows: .raised),
        "chris": .init(skin: 2, hairColor: 2, background: 6, hair: .sidePart, accessory: .cap, mouth: .grin),
        "daniel": .init(skin: 1, hairColor: 1, background: 7, hair: .sidePart, accessory: .headset, mouth: .neutral),
        "eric": .init(skin: 5, hairColor: 0, background: 4, hair: .short, accessory: .glasses, mouth: .smile),
        "george": .init(skin: 1, hairColor: 5, background: 2, hair: .short, facialHair: .beard, accessory: .glasses, mouth: .smile),
        "harry": .init(skin: 2, hairColor: 3, background: 0, hair: .short, facialHair: .beard, accessory: .helmet, mouth: .neutral, brows: .stern),
        "liam": .init(skin: 3, hairColor: 1, background: 1, hair: .quiff, accessory: .headphones, mouth: .grin, brows: .raised),
        "roger": .init(skin: 4, hairColor: 0, background: 6, hair: .curly, accessory: .sunglasses, mouth: .smirk),
        "will": .init(skin: 0, hairColor: 4, background: 3, hair: .curly, mouth: .grin),
        "alice": .init(skin: 1, hairColor: 3, background: 7, hair: .bob, accessory: .glasses, mouth: .smile),
        "aria": .init(skin: 4, hairColor: 0, background: 5, hair: .curly, accessory: .earrings, mouth: .smirk),
        "charlotte": .init(skin: 0, hairColor: 4, background: 4, hair: .bun, mouth: .smirk, brows: .raised),
        "jessica": .init(skin: 2, hairColor: 2, background: 1, hair: .ponytail, mouth: .grin, brows: .raised),
        "laura": .init(skin: 3, hairColor: 1, background: 2, hair: .long, accessory: .headphones, mouth: .grin),
        "lily": .init(skin: 0, hairColor: 3, background: 6, hair: .long, mouth: .smile),
        "matilda": .init(skin: 5, hairColor: 0, background: 3, hair: .bun, accessory: .glasses, mouth: .smile),
        "river": .init(skin: 2, hairColor: 5, background: 0, hair: .sidePart, accessory: .beanie, mouth: .neutral),
        "sarah": .init(skin: 1, hairColor: 2, background: 5, hair: .bob, accessory: .earrings, mouth: .smile),
    ]
}
