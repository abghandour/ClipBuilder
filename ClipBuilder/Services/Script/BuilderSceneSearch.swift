import Foundation

/// Shared by natural find requests and scene queries. Text comes only from the
/// frozen snapshot; no embedding, database reads, or provider calls are needed.
nonisolated enum BuilderSceneSearch {
    static let limit = 10

    struct Match: Sendable {
        let scene: SceneRecord
        let reason: String
        let entityHits: Int
        let textScore: Double
    }

    static func stem(_ value: String) -> String {
        LocalTextMatcher.tokens(value).map { word in
            for suffix in ["ing", "es", "s"] where word.count > suffix.count + 2 && word.hasSuffix(suffix) {
                return String(word.dropLast(suffix.count))
            }
            return word
        }.joined(separator: " ")
    }

    static func resolve(_ terms: String, request: String, library: ScriptLibrarySnapshot) -> BuilderProgram {
        var words = LocalTextMatcher.tokens(terms)
        var filter = SceneFilter()
        var remaining: [String] = []
        let people = library.people.filter { !$0.hidden }
        let tags = Array(Set(library.tags + library.scenes.flatMap(\.tags))).sorted()
        // Longest phrases first preserves multiword names and tags. Keys are
        // tokenized too, so alex_key and person:alex_key remain usable.
        let maximumPhraseLength = (people.flatMap { [$0.key, $0.name] } + tags)
            .map { LocalTextMatcher.tokens($0).count }.max() ?? 1
        while !words.isEmpty {
            var consumed = 0
            for count in stride(from: min(words.count, maximumPhraseLength), through: 1, by: -1) {
                let phrase = words.prefix(count).joined(separator: " ")
                let persons = people.filter {
                    [LocalTextMatcher.tokens($0.key).joined(separator: " "),
                     LocalTextMatcher.tokens($0.name).joined(separator: " ")].contains(phrase)
                }
                if persons.count == 1, let person = persons.first {
                    filter.people.append(person.key); consumed = count; break
                }
                let exactTags = tags.filter { LocalTextMatcher.tokens($0).joined(separator: " ") == phrase }
                if let tag = exactTags.first {
                    filter.tags.append(tag); consumed = count; break
                }
                let stems = tags.filter { !$0.lowercased().hasPrefix("person:") && stem($0) == stem(phrase) }
                if let tag = stems.first {
                    filter.tags.append(tag); consumed = count; break
                }
                let fuzzy = people.filter { person in
                    [person.key, person.name].contains { name in
                        let tokens = LocalTextMatcher.tokens(name)
                        return phrase.count >= 4 && tokens.count == count
                            && oneEditApart(phrase, tokens.joined(separator: " "))
                    }
                }
                if fuzzy.count == 1, let person = fuzzy.first {
                    filter.people.append(person.key); consumed = count; break
                }
            }
            if consumed > 0 { words.removeFirst(consumed); continue }
            let word = words.removeFirst()
            if LocalTextMatcher.stopWords.contains(word) { continue }
            remaining.append(word)
        }
        filter.people = Array(Set(filter.people)).sorted()
        filter.tags = Array(Set(filter.tags)).sorted()
        let rows = textRows(library)
        let unresolved = remaining.filter { term in
            !LocalTextMatcher.rank(query: term, rows: rows, useEmbedding: false).contains { $0.score > 0 }
        }
        if !unresolved.isEmpty { return .assistedFind(request: request, unresolved: unresolved) }
        if !remaining.isEmpty { filter.text = remaining.joined(separator: " ") }
        guard !filter.people.isEmpty || !filter.tags.isEmpty || filter.text != nil else {
            return .assistedFind(request: request, unresolved: [terms])
        }
        return .find(filter, presentation: request)
    }

    private static func oneEditApart(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count <= b.count { j += 1 }
            if a.count >= b.count { i += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }

    private static func fields(_ scene: SceneRecord, transcripts: [TranscriptRow]) -> [(String, String)] {
        var fields = [("narrative", scene.narrative ?? ""), ("tag", scene.tags.joined(separator: " ")),
                      ("video", scene.videoFilename)]
        fields += transcripts.filter {
            $0.startTime < scene.endTime && $0.endTime > scene.startTime
        }.map { ("transcript", $0.text) }
        return fields
    }

    static func textRows(_ library: ScriptLibrarySnapshot) -> [LocalTextMatcher.Row] {
        let transcripts = Dictionary(grouping: library.transcripts, by: \.videoID)
        return library.scenes.filter { !$0.excluded }.map { scene in
            .init(id: String(scene.id), fields: fields(scene, transcripts: transcripts[scene.videoID] ?? []).map { $0.1 })
        }
    }

    static func ranked(_ filter: SceneFilter, library: ScriptLibrarySnapshot) -> [Match] {
        let transcripts = Dictionary(grouping: library.transcripts, by: \.videoID)
        return library.scenes.compactMap { scene -> Match? in
            guard (filter.includeExcluded || !scene.excluded),
                  filter.video == nil || filter.video == scene.videoID else { return nil }
            return match(scene, filter: filter, transcripts: transcripts[scene.videoID] ?? [])
        }.sorted {
            if $0.entityHits != $1.entityHits { return $0.entityHits > $1.entityHits }
            if $0.textScore != $1.textScore { return $0.textScore > $1.textScore }
            let left = $0.scene.score.flatMap { $0.isFinite ? $0 : nil } ?? -.infinity
            let right = $1.scene.score.flatMap { $0.isFinite ? $0 : nil } ?? -.infinity
            if left != right { return left > right }
            return $0.scene.id < $1.scene.id
        }
    }

    private static func match(_ scene: SceneRecord, filter: SceneFilter, transcripts: [TranscriptRow]) -> Match? {
        if let minimum = filter.minScore {
            guard let score = scene.score, score.isFinite, score >= minimum else { return nil }
        }
        let sceneTags = Set(scene.tags.map { $0.lowercased() })
        guard filter.people.allSatisfy({ sceneTags.contains("person:" + $0.lowercased()) }),
              filter.tags.allSatisfy({ tag in
                  if tag.lowercased().hasPrefix("person:") { return sceneTags.contains(tag.lowercased()) }
                  return scene.tags.contains { stem($0) == stem(tag) }
              }) else { return nil }
        let fields = fields(scene, transcripts: transcripts)
        let row = LocalTextMatcher.Row(id: String(scene.id), fields: fields.map { $0.1 })
        var reasons = filter.people.map { "person: " + $0 } + filter.tags.map { "tag: " + $0 }
        var score = 0.0
        if let text = filter.text, !text.isEmpty {
            let terms = LocalTextMatcher.queryTokens(text)
            guard terms.included.allSatisfy({ term in
                LocalTextMatcher.rank(query: term, rows: [row], useEmbedding: false).first?.score ?? 0 > 0
            }), let hit = LocalTextMatcher.rank(query: text, rows: [row], useEmbedding: false).first,
                  hit.score > 0 else { return nil }
            score = hit.score
            for (source, value) in fields where LocalTextMatcher.rank(query: text,
                rows: [.init(id: row.id, fields: [value])], useEmbedding: false).first?.score ?? 0 > 0 {
                reasons.append(source + ": " + String(value.prefix(160)))
            }
        }
        if reasons.isEmpty { reasons = ["Matches scene filters"] }
        return Match(scene: scene, reason: String(reasons.joined(separator: " · ").prefix(500)),
                     entityHits: filter.people.count + filter.tags.count, textScore: score)
    }
}
