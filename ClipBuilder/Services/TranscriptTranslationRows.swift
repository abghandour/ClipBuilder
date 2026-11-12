import Foundation

/// The transcript editor shows a line's translations under the line. Pure
/// rules: which translation belongs to which line, which languages are
/// still missing, and which may be hidden.
nonisolated enum TranscriptTranslationRows {
    /// One language of the transcript on show: the spoken one or a translation.
    struct Language: Hashable, Sendable {
        var code: String
        var isTranslation: Bool
    }

    /// Translation rows per original row id, in `languages` order. A
    /// translation belongs to the line with its exact range, else the line
    /// it overlaps most, else the nearest; none is dropped.
    static func attached(_ rows: [TranscriptRow]) -> [Int64: [TranscriptRow]] {
        let originals = rows.filter { !$0.isTranslation }
        guard !originals.isEmpty else { return [:] }
        var exact: [String: Int64] = [:]
        for row in originals { exact[key(row)] = exact[key(row)] ?? row.id }
        var result: [Int64: [TranscriptRow]] = [:]
        for row in rows where row.isTranslation {
            let owner = exact[key(row)] ?? originals.max { overlap($0, row) < overlap($1, row) }.flatMap {
                overlap($0, row) > 0 ? $0.id : nil
            } ?? originals.min { abs($0.startTime - row.startTime) < abs($1.startTime - row.startTime) }?.id
            if let owner { result[owner, default: []].append(row) }
        }
        return result.mapValues { $0.sorted { ($0.language, $0.startTime) < ($1.language, $1.startTime) } }
    }

    /// The spoken language first, then each translation language.
    static func languages(_ rows: [TranscriptRow]) -> [Language] {
        let spoken = rows.first { !$0.isTranslation }.map { [Language(code: $0.language, isTranslation: false)] } ?? []
        return spoken + Set(rows.filter(\.isTranslation).map(\.language)).sorted().map { Language(code: $0, isTranslation: true) }
    }

    /// The project's caption languages this transcript is neither spoken
    /// in nor translated into yet, compared by language ("en" covers "en-US").
    static func missing(captions: [String], rows: [TranscriptRow]) -> [String] {
        let have = Set(languages(rows).map { ProjectLanguageResolver.languageCode($0.code) })
        var seen: Set<String> = []
        return captions.filter { !$0.isEmpty }.filter { caption in
            let code = ProjectLanguageResolver.languageCode(caption)
            return !have.contains(code) && seen.insert(code).inserted
        }
    }

    /// A pill was clicked: the language hides or shows again, but the last
    /// one on show stays.
    static func toggling(_ language: Language, hidden: Set<Language>, all: [Language]) -> Set<Language> {
        var hidden = hidden.intersection(all)
        if hidden.contains(language) {
            hidden.remove(language)
        } else if all.count - hidden.count > 1 {
            hidden.insert(language)
        }
        return hidden
    }

    private static func key(_ row: TranscriptRow) -> String { "\(row.startTime)|\(row.endTime)" }

    private static func overlap(_ a: TranscriptRow, _ b: TranscriptRow) -> Double {
        min(a.endTime, b.endTime) - max(a.startTime, b.startTime)
    }
}
