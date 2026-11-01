import Foundation

/// Keyword routing and wording shared by the page assistants (Phase 2 of
/// docs/Page-Assistant-Plan.md). Pure. Phase 3 adds AI understanding behind
/// `unrecognized`: an assistant's `handle` tries its keywords first and
/// falls back to it.
nonisolated enum AssistantText {
    static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `text` contains any of `words` (lowercase substrings).
    /// A word matches at a word start, so "tag" matches "tags" and "tagging"
    /// but not "octagon"; multi-word markers match as phrases.
    static func mentions(_ text: String, _ words: [String]) -> Bool {
        let text = normalized(text)
        return words.contains { word in
            var start = text.startIndex
            while let range = text.range(of: word, range: start..<text.endIndex) {
                if range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isLetter {
                    return true
                }
                start = range.upperBound
            }
            return false
        }
    }

    /// The words after the first marker found, in marker order:
    /// "find scenes about the knockout" with ["about "] → "the knockout".
    /// Leading filler ("scenes", "me", "the moment") is dropped; nil when
    /// nothing is left.
    static func remainder(of text: String, after markers: [String]) -> String? {
        let trim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        for marker in markers {
            guard let range = text.range(of: marker, options: .caseInsensitive) else { continue }
            var rest = String(text[range.upperBound...]).trimmingCharacters(in: trim)
            for filler in ["scenes ", "scene ", "moments ", "me "] where rest.lowercased().hasPrefix(filler) {
                rest = String(rest.dropFirst(filler.count)).trimmingCharacters(in: trim)
            }
            if !rest.isEmpty { return rest }
        }
        return nil
    }

    /// "1 source", "3 sources".
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : plural ?? singular + "s")"
    }

    /// Nothing in the page's keywords matched. Phase 3 asks the AI here.
    static func unrecognized(page: String, examples: [String]) -> AskAIOutcome {
        let example = examples.first.map { " Try “\($0)”," } ?? ""
        return .unavailable("Ask AI on \(page) does not understand that yet.\(example) or run a suggestion.")
    }

    /// Run `actionID` from `actions` for a typed request; `fallback` when the
    /// page does not offer it. `AssistantModel.send` records the outcome.
    @MainActor
    static func run(_ actionID: String?, actions: [AssistantAction], store: AppStore,
                    fallback: AskAIOutcome) -> AskAIOutcome {
        guard let actionID, let action = actions.first(where: { $0.id == actionID }) else { return fallback }
        return action.isAvailable(store) ? action.run(store) : .unavailable("\(action.title) is not available right now.")
    }
}

nonisolated extension AssistantAction {
    /// An action the visible page's view runs because it owns the sheet,
    /// selection or form state: sent through `store.assistant.pendingCommand`
    /// and consumed with `.onAssistantCommand(_:)`.
    /// `namespace` routes it to the view that owns it when the id alone
    /// does not (the Wizard's shared `wizard.*` ids go to Express or Full).
    static func command(_ id: String, _ title: String, _ systemImage: String, message: String,
                        namespace: String? = nil,
                        available: @escaping @MainActor @Sendable (AppStore) -> Bool = { _ in true }) -> AssistantAction {
        AssistantAction(id: id, title: title, systemImage: systemImage, isAvailable: available, handledByPage: true) { store in
            store.assistant.sendCommand(id, namespace: namespace)
            return .handled(message)
        }
    }

    /// Go to another sidebar page.
    @MainActor
    static func open(_ id: String, _ section: SidebarSection, title: String) -> AssistantAction {
        AssistantAction(id: id, title: title, systemImage: section.systemImage) { store in
            store.requestedSection = section
            return .handled("Opened \(section.title).")
        }
    }
}

nonisolated extension AssistantPageState {
    func count(_ key: String) -> Int { counts[key] ?? 0 }
    func flag(_ key: String) -> Bool { flags[key] ?? false }
    func value(_ key: String) -> String? { values[key] }
    /// `value` with "" read as absent: published state merges by key, so a
    /// page clears a value by publishing "".
    func text(_ key: String) -> String? { values[key].flatMap { $0.isEmpty ? nil : $0 } }
}

extension AssistantModel {
    /// The state `page` last published, or an empty one.
    func state(_ page: String) -> AssistantPageState { pageState[page] ?? AssistantPageState() }
}
