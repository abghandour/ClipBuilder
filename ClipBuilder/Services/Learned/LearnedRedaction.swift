import Foundation

nonisolated enum LearnedRedaction {
    enum Failure: Error { case unclassifiedField(String), invalidDocument }

    /// Explicit, closed schema. A new encoded property must be classified here.
    static let documentKeys: Set<String> = ["version", "contributor", "sections"]
    static let sectionKeys: Set<String> = ["kind", "enabled", "updatedAt", "evidence", "items"]
    static let itemKeys: Set<String> = ["id", "field", "text", "pinned", "evidence", "updatedAt", "frames", "numbers"]
    static let fields: [LearnedPreferences.Kind: Set<String>] = [
        .style: ["houseStyle", "hookStyle", "layout", "pacing", "captionLanguage"],
        .taste: ["rubric", "category"], .lessons: ["lesson"],
        .vocabulary: ["tag", "hashtag"], .benchmarks: ["summary", "slot", "hashtagLift", "topTrait", "bottomTrait"],
        .people: ["person"], .research: ["summary", "queryPlan"],
    ]
    static let numberKeys: Set<String> = ["durationMin", "durationMax", "durationMedian", "cutsPerMinute",
        "savesPer1k", "sharesPer1k", "commentsPer1k", "weekday", "hour", "posts", "lift", "reels", "studies"]

    static func validateSchema(_ data: Data) throws {
        func check(_ object: [String: Any], keys: Set<String>) throws {
            if let key = Set(object.keys).subtracting(keys).sorted().first { throw Failure.unclassifiedField(key) }
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidDocument
        }
        try check(object, keys: documentKeys)
        for section in object["sections"] as? [[String: Any]] ?? [] {
            try check(section, keys: sectionKeys)
            for item in section["items"] as? [[String: Any]] ?? [] { try check(item, keys: itemKeys) }
        }
    }

    /// Free text can itself contain secrets. Remove URLs, paths, handles and
    /// credential-bearing lines even when their containing field is allowed.
    static func text(_ value: String, secrets: [String] = []) -> String {
        var result = value
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "")
        }
        result = result.components(separatedBy: .newlines).filter {
            let line = $0.lowercased()
            return !["cookie", "ig_", "bearer ", "api_key", "access_token", "refresh_token"].contains(where: line.contains)
        }.joined(separator: "\n")
        for pattern in [#"(?i)\b(?:https?|file)://\S+"#, #"(?:~?/|[A-Za-z]:\\)[^\s,;]+"#,
                        #"[\w.+-]+@[\w.-]+"#, #"(?<!\w)@[\w.]*"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isFrame(_ name: String, contributor: String) -> Bool {
        let prefix = "learned/\(contributor)/frames/"
        guard name.hasPrefix(prefix) else { return false }
        let hash = String(name.dropFirst(prefix.count).dropLast(4))
        return name.hasSuffix(".jpg") && hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) }
    }

    static func apply(_ input: LearnedPreferences, secrets: [String] = [], publishing: Bool = false) throws -> LearnedPreferences {
        try validateSchema(JSONEncoder().encode(input))
        guard input.version == LearnedPreferences.currentVersion,
              !input.contributor.isEmpty, input.contributor != ".", input.contributor != "..",
              ProfileStore.sanitize(input.contributor) == input.contributor,
              text(input.contributor) == input.contributor else { throw Failure.invalidDocument }
        guard Set(input.sections.map(\.kind)).count == input.sections.count else { throw Failure.invalidDocument }
        var result = input
        for index in result.sections.indices {
            let section = result.sections[index]
            result.sections[index].evidence = text(section.evidence, secrets: secrets)
            result.sections[index].items = publishing && !section.enabled ? [] : section.items.compactMap { original in
                guard fields[section.kind]?.contains(original.field) == true else { return nil }
                var item = original
                item.id = text(item.id, secrets: secrets)
                item.text = text(item.text, secrets: secrets)
                item.evidence = text(item.evidence, secrets: secrets)
                item.frames = item.frames.filter { isFrame($0, contributor: input.contributor) }
                item.numbers = item.numbers.filter { numberKeys.contains($0.key) && $0.value.isFinite }
                return item
            }
        }
        return result
    }
}
