import Foundation

/// Content gap report: a strategist's pass over the whole pipeline — what's
/// analyzed but never rendered, curated but unused, imported but untouched,
/// and how the publishing cadence looks — returned as a prioritized
/// checklist referencing actual files.
nonisolated enum GapReporter {

    struct Section: Identifiable, Sendable, Hashable {
        var title: String
        var items: [String]

        var id: String { title }
    }

    static func prompt(inventory: String, domain: String) -> String {
        """
        You are the content strategist for a \(domain) short-form video brand. Below is the full state of their production pipeline. Produce a short, prioritized to-do report: what to post next, what's sitting unused, and what's blocking more output.

        \(inventory)

        Rules:
        - Be concrete: reference the actual filenames and numbers above, never generic advice ("post consistently").
        - Prioritize: ready-to-render material first, then preparation work (analysis, curation), then cadence/mix observations.
        - 2–4 sections, at most 5 items each, each item one sentence.

        Return ONLY a JSON object:
        {"sections": [{"title": "<short heading>", "items": ["<one-sentence action>", ...]}]}
        """
    }

    static func parse(_ response: String) -> [Section] {
        guard let object = AIResponseParser.jsonObject(from: response),
              let raw = object["sections"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let title = (entry["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let items = (entry["items"] as? [Any] ?? [])
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty else { return nil }
            return Section(title: title, items: items)
        }
    }

    /// The report as plain text, for the Copy button.
    static func plainText(_ sections: [Section]) -> String {
        sections.map { section in
            "## \(section.title)\n" + section.items.map { "- \($0)" }.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}
