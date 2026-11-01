import Foundation

/// One thing the page knows, or one of its current settings: a stable key
/// for rules, a label and a display value for the context line's tooltip.
nonisolated struct AssistantFact: Equatable, Hashable, Sendable {
    var key: String
    var label: String
    var value: String

    init(key: String, label: String, value: String) {
        self.key = key
        self.label = label
        self.value = value
    }

    init(_ key: String, _ label: String, _ value: String) {
        self.init(key: key, label: label, value: value)
    }

    init(_ key: String, _ label: String, on: Bool) {
        self.init(key: key, label: label, value: on ? AssistantContext.on : AssistantContext.off)
    }

    init(_ key: String, _ label: String, _ count: Int) {
        self.init(key: key, label: label, value: String(count))
    }
}

/// What Ask AI sees on one page (docs/Page-Assistant-Plan.md): built by the
/// page's assistant from the store and the page's published state, read by
/// the pure `suggestions(for:)` rules and shown as the popover's context line.
nonisolated struct AssistantContext: Equatable, Sendable {
    static let on = "on"
    static let off = "off"
    static let selectionLimit = 20

    var page: String
    var subpage: String?
    var facts: [AssistantFact]
    var settings: [AssistantFact]
    var selection: [String]
    /// Stable across launches for equal content (FNV-1a, not `Hasher`), so a
    /// later AI ranking can be cached by it.
    var fingerprint: String
    /// "Express · Highlights · Auto · captions off · 1 source"
    var summaryLine: String

    /// `summary` lists the context line's parts after the page name, in
    /// order; nil uses the first few fact and setting values.
    init(page: String, subpage: String? = nil, facts: [AssistantFact] = [], settings: [AssistantFact] = [],
         selection: [String] = [], summary: [String]? = nil) {
        self.page = page
        self.subpage = subpage
        self.facts = facts
        self.settings = settings
        self.selection = Array(selection.prefix(Self.selectionLimit))
        let parts = summary ?? (facts + settings).prefix(4).map(\.value)
        summaryLine = Self.summaryLine(page: page, subpage: subpage, parts: parts)
        // The full selection, not the shown prefix: swapping the 21st item
        // must change the fingerprint so a pending answer goes stale.
        fingerprint = Self.fingerprint(page: page, subpage: subpage, facts: facts, settings: settings,
                                       selection: selection)
    }

    static func summaryLine(page: String, subpage: String?, parts: [String]) -> String {
        ([subpage ?? page] + parts)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    static func fingerprint(page: String, subpage: String?, facts: [AssistantFact], settings: [AssistantFact],
                            selection: [String]) -> String {
        var text = "page=\(page)\u{1F}sub=\(subpage ?? "")\u{1E}"
        for fact in facts { text += "f:\(fact.key)=\(fact.value)\u{1F}" }
        text += "\u{1E}"
        for setting in settings { text += "s:\(setting.key)=\(setting.value)\u{1F}" }
        text += "\u{1E}" + selection.joined(separator: "\u{1F}")
        return stableHash(text)
    }

    /// FNV-1a of `text`'s UTF-8, in hex: the same on every launch, unlike `Hasher`.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Every fact and setting, one per line, for the context line's tooltip.
    var detailText: String {
        var lines = facts.map { "\($0.label): \($0.value)" }
        if !settings.isEmpty { lines += ["Settings:"] + settings.map { "  \($0.label): \($0.value)" } }
        if !selection.isEmpty { lines.append("Selected: \(selection.joined(separator: ", "))") }
        return lines.isEmpty ? summaryLine : lines.joined(separator: "\n")
    }

    /// The value for `key`, facts first, then settings.
    func value(_ key: String) -> String? {
        (facts.first { $0.key == key } ?? settings.first { $0.key == key })?.value
    }

    func int(_ key: String) -> Int? { value(key).flatMap { Int($0) } }
    func double(_ key: String) -> Double? { value(key).flatMap { Double($0) } }
    func isOn(_ key: String) -> Bool { value(key) == Self.on }
    func isOff(_ key: String) -> Bool { value(key) == Self.off }
}

/// What the assistant would do next on this page. `id` names the topic and
/// the reason (`<page>.<topic>.<reason>`); a dismissal is keyed by the id and
/// a signature of the reason (`dismissKey`), so a dismissed suggestion comes
/// back when its reason changes even when its id does not ("3 flags" → "5 flags").
nonisolated struct AssistantSuggestion: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case setting, action, insight }
    var id: String
    var kind: Kind
    var title: String
    var reason: String
    /// The reason as the rules wrote it. The AI ranking may rephrase
    /// `reason`; dismissals follow this, so a rephrase alone never un-hides
    /// a row and a changed rule reason always does.
    var reasonKey: String
    /// The `AssistantAction` it runs; nil for an insight with nothing to run.
    var actionID: String?
    /// Nil when rule-based; set by the AI ranking (Phase 3).
    var provenance: AIProvenance?

    init(id: String, kind: Kind, title: String, reason: String, actionID: String? = nil,
         provenance: AIProvenance? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.reason = reason
        self.reasonKey = reason
        self.actionID = actionID
        self.provenance = provenance
    }

    /// What a dismissal stores: the id and a stable hash of `reasonKey`.
    var dismissKey: String { Self.dismissKey(id: id, reason: reasonKey) }

    static func dismissKey(id: String, reason: String) -> String {
        "\(id)#\(AssistantContext.stableHash(reason))"
    }
}

/// Work the page already offers from a visible control, runnable from a
/// suggestion. `systemImage` is the page's own symbol for it, never a new one.
nonisolated struct AssistantAction: Identifiable, Sendable {
    var id: String
    var title: String
    var systemImage: String
    var isAvailable: @MainActor @Sendable (AppStore) -> Bool
    var run: @MainActor @Sendable (AppStore) -> AskAIOutcome
    /// The visible page's view runs it (`AssistantAction.command`) and
    /// validates it against its own state when it consumes the command, so
    /// an AI answer that changes the page's settings first (a folder, a
    /// filter) is judged on the page as it will be, not as it was.
    var handledByPage: Bool

    init(id: String, title: String, systemImage: String,
         isAvailable: @escaping @MainActor @Sendable (AppStore) -> Bool = { _ in true },
         handledByPage: Bool = false,
         run: @escaping @MainActor @Sendable (AppStore) -> AskAIOutcome) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isAvailable = isAvailable
        self.handledByPage = handledByPage
        self.run = run
    }
}

/// Page state the store cannot see (filters, sort, counts a view loaded),
/// published by the page through `.askAI(_:pageState:)` and read by its
/// assistant's `context(store:)`. Values merge by key.
nonisolated struct AssistantPageState: Equatable, Sendable {
    var counts: [String: Int] = [:]
    var flags: [String: Bool] = [:]
    var values: [String: String] = [:]
    /// A patch field: nil leaves the published selection alone (a partial
    /// update such as a count), `[]` clears it.
    var selection: [String]?

    init(counts: [String: Int] = [:], flags: [String: Bool] = [:], values: [String: String] = [:],
         selection: [String]? = nil) {
        self.counts = counts
        self.flags = flags
        self.values = values
        self.selection = selection
    }

    /// `other`'s keys replace this state's; a published selection (even an
    /// empty one) replaces it, an omitted one keeps it.
    func merging(_ other: AssistantPageState) -> AssistantPageState {
        var result = self
        result.counts.merge(other.counts) { _, new in new }
        result.flags.merge(other.flags) { _, new in new }
        result.values.merge(other.values) { _, new in new }
        if let selection = other.selection { result.selection = selection }
        return result
    }
}

/// A setting Ask AI may change from typed text (Phase 3 whitelist): its key
/// in the AI's `settings` patch, a label, and the values it accepts.
/// `normalize` turns whatever JSON the model sent into the one string form
/// the page applies, or nil when the value is not allowed.
nonisolated struct AssistantSetting: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case bool
        case integer(ClosedRange<Int>)
        /// Allowed values; `choiceLabels` may name them for the prompt.
        case choice([String])
        case text(maxLength: Int)
    }

    static let `true` = "true"
    static let `false` = "false"

    var key: String
    var label: String
    var kind: Kind
    /// Display names for `.choice` values ("all" → "All"); matched too.
    var choiceLabels: [String: String] = [:]

    init(_ key: String, _ label: String, _ kind: Kind, choiceLabels: [String: String] = [:]) {
        self.key = key
        self.label = label
        self.kind = kind
        self.choiceLabels = choiceLabels
    }

    /// What the prompt tells the model it may send.
    var allowedDescription: String {
        switch kind {
        case .bool: return "true or false"
        case .integer(let range): return "integer \(range.lowerBound)–\(range.upperBound)"
        case .text(let limit): return "text, at most \(limit) characters (\"\" clears it)"
        case .choice(let values):
            let shown = values.map { value in
                choiceLabels[value].map { $0 == value ? value : "\(value) (\($0))" } ?? value
            }
            return "one of: " + shown.joined(separator: ", ")
        }
    }

    /// The JSON value as the page applies it, or nil when not allowed.
    func normalize(_ raw: Any) -> String? {
        switch kind {
        case .bool:
            if let number = raw as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? Self.true : Self.false }
                if number == 1 { return Self.true }
                if number == 0 { return Self.false }
                return nil
            }
            guard let text = raw as? String else { return nil }
            switch AssistantText.normalized(text) {
            case "true", "on", "yes", "1": return Self.true
            case "false", "off", "no", "0": return Self.false
            default: return nil
            }
        case .integer(let range):
            let value: Int?
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                let double = number.doubleValue
                value = double.isFinite && abs(double) < 1e9 ? Int(double.rounded()) : nil
            } else if let text = raw as? String {
                value = Int(String(text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }))
            } else {
                value = nil
            }
            return value.flatMap { range.contains($0) ? String($0) : nil }
        case .choice(let values):
            let text: String
            if let string = raw as? String { text = string }
            else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { text = number.stringValue }
            else { return nil }
            let wanted = AssistantText.normalized(text)
            return values.first { AssistantText.normalized($0) == wanted }
                ?? values.first { choiceLabels[$0].map(AssistantText.normalized) == wanted }
        case .text(let limit):
            guard let text = raw as? String else { return nil }
            return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
    }
}
