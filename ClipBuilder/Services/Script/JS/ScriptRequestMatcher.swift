import Foundation

/// Ranking and extraction use only the request and the captured values.
nonisolated enum ScriptRequestMatcher {
    struct Candidate: Sendable {
        let record: BuilderScriptRecord
        let score: Double
        let extractedParameters: [String: ScriptValue]
        let runnable: Bool
    }

    enum Confidence: Equatable { case confident, ambiguous, none }

    static func confidence(_ candidates: [Candidate]) -> Confidence {
        guard let best = candidates.first else { return .none }
        let next = candidates.dropFirst().first?.score ?? 0
        if best.score >= 0.75, best.score - next >= 0.2 { return .confident }
        return best.score >= 0.4 ? .ambiguous : .none
    }

    /// Decode the stored schema with the same strict parser used for execution.
    static func header(for record: BuilderScriptRecord) throws -> ScriptHeader {
        let value: ScriptValue = .object([
            "name": .string(record.name), "description": .string(record.description),
            "mode": .string(record.mode),
            "params": try ScriptStrictJSON.decode(Data(record.paramsJSON.utf8)),
            "requires": try ScriptStrictJSON.decode(Data(record.requiresJSON.utf8))
        ])
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            .replacingOccurrences(of: "*/", with: "*\\/")
        let header = try ScriptHeader.parse("/** clipbuilder-script\n" + json + "\n*/")
        // A stale metadata row must never route different executable semantics.
        let executable = try ScriptHeader.parse(record.source)
        let storedMetadata = try header.metadataJSON()
        let sourceMetadata = try executable.metadataJSON()
        guard executable.name == header.name, executable.description == header.description,
              executable.mode == header.mode,
              try ScriptStrictJSON.decode(Data(sourceMetadata.params.utf8)) == ScriptStrictJSON.decode(Data(storedMetadata.params.utf8)),
              try ScriptStrictJSON.decode(Data(sourceMetadata.requires.utf8)) == ScriptStrictJSON.decode(Data(storedMetadata.requires.utf8)) else {
            throw ScriptError.invalid("Saved script metadata does not match its source.")
        }
        return executable
    }

    static func match(request: String, scripts: [BuilderScriptRecord], capture: ScriptCapture) -> [Candidate] {
        let words = tokens(request)
        guard !words.isEmpty else { return [] }
        return scripts.compactMap { record -> Candidate? in
            guard let header = try? Self.header(for: record) else { return nil }
            var parameters: [String: ScriptValue] = [:]
            var extractedWords: Set<String> = []
            let numbers = request.matches(of: /-?\d+(?:\.\d+)?/)
                .compactMap { Double($0.output) }
            let numeric = header.params.filter { ["number", "time", "track"].contains($0.type) }
            for parameter in header.params {
                if numeric.count == 1, numbers.count == 1, numeric[0].name == parameter.name {
                    parameters[parameter.name] = .number(numbers[0])
                } else if parameter.type == "choice", let choices = parameter.choices {
                    let matches = choices.filter { containsPhrase(request, $0) }
                    if matches.count == 1 {
                        parameters[parameter.name] = .string(matches[0])
                        extractedWords.formUnion(tokens(matches[0]))
                    }
                } else if parameter.type == "string" {
                    let label = tokens(parameter.name + " " + (parameter.label ?? ""))
                    if !label.isDisjoint(with: ["person", "people", "roster"]) {
                        let people = capture.library.people.filter {
                            containsPhrase(request, $0.key) || containsPhrase(request, $0.name)
                                || containsPhrase(request, $0.displayName)
                        }
                        if people.count == 1 {
                            parameters[parameter.name] = .string(people[0].key)
                            extractedWords.formUnion(tokens(people[0].key + " " + people[0].name + " " + people[0].displayName))
                        }
                    } else if label.contains("tag") {
                        let tags = capture.library.tags.filter { containsPhrase(request, $0) }
                        if tags.count == 1 {
                            parameters[parameter.name] = .string(tags[0])
                            extractedWords.formUnion(tokens(tags[0]))
                        }
                    }
                }
            }
            let name = tokens(record.name)
            let description = tokens(record.description)
            let meaningful = words.subtracting(extractedWords)
            let overlap = meaningful.intersection(name.union(description))
            guard !name.isEmpty, !meaningful.isEmpty, !overlap.isEmpty else { return nil }
            let nameCoverage = Double(meaningful.intersection(name).count) / Double(name.count)
            let requestCoverage = Double(overlap.count) / Double(meaningful.count)
            var score = 0.45 * nameCoverage + 0.45 * requestCoverage
            if containsPhrase(request, record.name) { score += 0.2 }
            if !parameters.isEmpty { score += 0.05 }
            // Extra instructions and negation must be interpreted by the agent/classifier.
            let extractedNumberCount = parameters.values.filter { value in
                if case .number = value { return true }
                return false
            }.count
            if requestCoverage < 1 || numbers.count > extractedNumberCount
                || !words.isDisjoint(with: ["not", "except", "without", "then", "and"]) {
                score = min(score, 0.7)
            }
            guard score >= 0.4 else { return nil }
            let data = try? JSONEncoder().encode(parameters)
            let complete = header.params.allSatisfy { parameters[$0.name] != nil || $0.defaultValue != nil }
            let resolved = data.flatMap { try? header.resolve($0, capture: capture).0 }
            let values = resolved.flatMap { try? JSONDecoder().decode([String: ScriptValue].self, from: $0) }
            return Candidate(record: record, score: min(1, score),
                             extractedParameters: values ?? parameters, runnable: complete && resolved != nil)
        }.sorted { $0.score == $1.score ? $0.record.id.uuidString < $1.record.id.uuidString : $0.score > $1.score }
    }

    private static func normalized(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        let phrase = normalized(phrase)
        guard !phrase.isEmpty else { return false }
        return (" " + normalized(text).joined(separator: " ") + " ")
            .contains(" " + phrase.joined(separator: " ") + " ")
    }

    private static func tokens(_ text: String) -> Set<String> {
        let stop: Set<String> = ["a", "an", "the", "all", "every", "with", "to", "of", "into", "in", "on", "at", "please", "my", "this", "it"]
        return Set(normalized(text).compactMap { word in
            guard !stop.contains(word), Double(word) == nil else { return nil }
            switch word {
            case "selected", "selection", "selecting": return "select"
            case "pieces", "parts", "piece", "part", "evenly", "equal": return "equal"
            case "muted", "muting": return "mute"
            case "removed", "removing": return "remove"
            default: return word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
            }
        })
    }
}
