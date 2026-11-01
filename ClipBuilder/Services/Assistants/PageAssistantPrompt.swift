import Foundation

/// Prompt and reply parsing for `AITask.assist` (Phase 3 of
/// docs/Page-Assistant-Plan.md). Pure. One task, two modes:
///
/// - Ranking (`question == nil`): order up to five of the page's rule
///   suggestions, optionally rephrase their reasons, and optionally add a
///   suggestion that runs one catalogue action.
/// - Understanding (`question != nil`): read a typed request as one
///   catalogue action and a patch of whitelisted settings.
///
/// The catalogue is the only source of action ids. Parsing drops (ranking)
/// or refuses (understanding) anything outside it.
nonisolated enum PageAssistantPrompt {
    /// A catalogue entry: an `AssistantAction` the page offers right now.
    struct Action: Equatable, Sendable {
        var id: String
        var title: String

        init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// One ranked row: a rule suggestion id or a catalogue action id, with
    /// the model's reason when it rephrased or added one.
    struct Ranked: Equatable, Sendable {
        var id: String
        var reason: String?
    }

    /// A validated answer to a typed request.
    struct Answer: Equatable, Sendable {
        var actionID: String?
        /// Setting key → value in `AssistantSetting.normalize` form.
        var settings: [String: String]
        var reply: String
    }

    enum Parsed: Equatable, Sendable {
        case answer(Answer)
        /// The model named an action or setting the page does not offer, or
        /// a value it does not allow; the message says which.
        case refused(String)
        case unreadable
    }

    static let rankingLimit = 5
    static let reasonLimit = 160
    static let replyLimit = 300

    /// Section headers, in prompt order. Tests check them.
    enum Section {
        static let page = "## PAGE"
        static let facts = "## FACTS"
        static let settings = "## CURRENT SETTINGS"
        static let selection = "## SELECTION"
        static let actions = "## ACTIONS"
        static let suggestions = "## RULE SUGGESTIONS"
        static let changeable = "## CHANGEABLE SETTINGS"
        static let request = "## REQUEST"
        static let task = "## TASK"
        static let answer = "## ANSWER FORMAT"
    }

    static func build(context: AssistantContext, actions: [Action], settings: [AssistantSetting],
                      question: String?, suggestions: [AssistantSuggestion] = []) -> String {
        var parts: [String] = []
        parts.append("""
        You are Ask AI inside Clip Builder, a macOS app that turns a profile's source footage into \
        short-form clips. You are on the "\(context.page)" page. You can only use what this page \
        offers: the actions and settings listed below, by their exact ids. Never invent an id.
        """)

        var page = ["Page: \(context.page)"]
        if let subpage = context.subpage { page.append("View: \(subpage)") }
        page.append("Summary: \(context.summaryLine)")
        parts.append(Section.page + "\n" + page.joined(separator: "\n"))

        parts.append(Section.facts + "\n" + lines(context.facts.map { "- \($0.key) (\($0.label)): \(clip($0.value))" }))
        parts.append(Section.settings + "\n" + lines(context.settings.map { "- \($0.key) (\($0.label)): \(clip($0.value))" }))
        parts.append(Section.selection + "\n" + lines(context.selection.map { "- \(clip($0))" }))
        parts.append(Section.actions + " (the only action ids you may use)\n"
                     + lines(actions.map { "- \($0.id): \(clip($0.title))" }))

        if let question {
            parts.append(Section.changeable + " (the only setting keys you may change)\n"
                         + lines(settings.map { "- \($0.key) (\(clip($0.label))): \($0.allowedDescription)" }))
            parts.append(Section.request + "\n" + question.trimmingCharacters(in: .whitespacesAndNewlines))
            parts.append(Section.task + "\n" + """
            Read the request against this page. Pick at most one action from ACTIONS that does what \
            was asked, and any settings from CHANGEABLE SETTINGS it asks to change, with allowed values \
            only. Settings are applied before the action runs. If the page cannot do it, set "action" \
            to null, leave "settings" empty, and say why in "reply". "reply" is one short sentence to \
            the user saying what you did.
            """)
            parts.append(Section.answer + "\n" + """
            Reply with JSON only, no prose and no code fence:
            {"action": "<action id>" or null, "settings": {"<setting key>": <value>}, "reply": "<one sentence>"}
            """)
        } else {
            parts.append(Section.suggestions + " (computed by rules from the facts above)\n"
                         + lines(suggestions.map { "- \($0.id): \(clip($0.title)) — \(clip($0.reason))" }))
            parts.append(Section.task + "\n" + """
            Rank what the user should do next on this page, best first, at most \(rankingLimit) rows. \
            Use rule suggestion ids as they are; you may rewrite a reason in one short sentence that \
            cites the facts. You may add a row for an action id from ACTIONS that the rules missed, \
            with a reason. Leave out rows that do not help. Do not repeat an id.
            """)
            parts.append(Section.answer + "\n" + """
            Reply with JSON only, no prose and no code fence:
            {"suggestions": [{"id": "<rule suggestion id or action id>", "reason": "<optional, one sentence>"}]}
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    /// The ranked rows, valid ids only, unique, at most `rankingLimit`; nil
    /// when the reply is not the expected JSON.
    static func parseRanking(_ raw: String, suggestions: [AssistantSuggestion], actions: [Action]) -> [Ranked]? {
        guard let json = AIResponseParser.jsonObject(from: raw),
              let items = json["suggestions"] as? [Any] else { return nil }
        let known = Set(suggestions.map(\.id)).union(actions.map(\.id))
        var seen: Set<String> = []
        var result: [Ranked] = []
        for item in items {
            let id: String?
            var reason: String?
            if let text = item as? String {
                id = text
            } else if let object = item as? [String: Any] {
                id = object["id"] as? String
                reason = (object["reason"] as? String).flatMap(cleanReason)
            } else {
                id = nil
            }
            guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), known.contains(id),
                  seen.insert(id).inserted else { continue }
            result.append(Ranked(id: id, reason: reason))
            if result.count == rankingLimit { break }
        }
        return result
    }

    static func parseAnswer(_ raw: String, actions: [Action], settings: [AssistantSetting]) -> Parsed {
        guard let json = AIResponseParser.jsonObject(from: raw) else { return .unreadable }
        var actionID: String?
        switch json["action"] {
        case nil, is NSNull: actionID = nil
        case let text as String:
            let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, id.lowercased() != "null" {
                guard actions.contains(where: { $0.id == id }) else {
                    return .refused("Ask AI picked an action this page does not offer.")
                }
                actionID = id
            }
        default:
            return .unreadable
        }
        var patch: [String: String] = [:]
        switch json["settings"] {
        case nil, is NSNull: break
        case let object as [String: Any]:
            for key in object.keys.sorted() {
                guard let setting = settings.first(where: { $0.key == key }) else {
                    return .refused("Ask AI cannot change “\(key)” on this page.")
                }
                guard let raw = object[key], let value = setting.normalize(raw) else {
                    return .refused("That is not a valid value for \(setting.label).")
                }
                patch[key] = value
            }
        default:
            return .unreadable
        }
        let reply = String(((json["reply"] as? String) ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(replyLimit))
        if actionID == nil, patch.isEmpty {
            return .refused(reply.isEmpty ? "Ask AI could not match that to anything on this page." : reply)
        }
        return .answer(Answer(actionID: actionID, settings: patch, reply: reply))
    }

    // MARK: - Helpers

    private static func lines(_ rows: [String]) -> String {
        rows.isEmpty ? "(none)" : rows.joined(separator: "\n")
    }

    /// One line, bounded, so a long title or instruction cannot swamp the prompt.
    private static func clip(_ text: String, limit: Int = 200) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    private static func cleanReason(_ text: String) -> String? {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return nil }
        return flat.count > reasonLimit ? String(flat.prefix(reasonLimit - 1)) + "…" : flat
    }
}
