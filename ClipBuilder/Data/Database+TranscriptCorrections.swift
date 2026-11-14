import Foundation

extension Database {
    /// Mark words right: a words-only write, the text and the transcriber's
    /// originals stay untouched. A line whose word is no longer the one
    /// expected is skipped whole.
    func confirmTranscriptWords(_ expected: [Int64: [Int: String]]) throws {
        for (id, positions) in expected where !positions.isEmpty {
            guard let words = try storedWords(id: id),
                  let confirmed = TranscriptWordRules.confirming(positions, words: words) else { continue }
            try storeWords(confirmed, id: id)
        }
    }

    /// One Proofread part's suggestions. `covered` is every word that part
    /// read (line id to word positions): their old suggestions go first, so
    /// a second run replaces the first. `read` is the word it saw at each of
    /// them: a line edited since is left alone. Returns how many suggestions landed.
    @discardableResult
    func storeTranscriptSuggestions(_ suggestions: [Int64: [Int: (heard: String, suggestion: TranscriptWordSuggestion)]],
                                    covered: [Int64: Set<Int>], read: [Int64: [Int: String]] = [:]) throws -> Int {
        try connection.transaction {
            var count = 0
            for (id, positions) in covered {
                guard let words = try storedWords(id: id) else { continue }
                let result = TranscriptWordRules.suggesting(suggestions[id] ?? [:], covered: positions, read: read[id], words: words)
                guard result.words != words else { continue }
                try storeWords(result.words, id: id)
                count += result.count
            }
            return count
        }
    }

    private func storedWords(id: Int64) throws -> [TranscriptWord]? {
        try connection.query("SELECT words FROM transcripts WHERE id = ? AND is_translation = 0", [.integer(id)])
            .first?["words"]?.stringValue.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([TranscriptWord].self, from: $0) }
    }

    private func storeWords(_ words: [TranscriptWord], id: Int64) throws {
        let json = String(decoding: try JSONEncoder().encode(words), as: UTF8.self)
        try connection.execute("UPDATE transcripts SET words = ? WHERE id = ?", [.text(json), .integer(id)])
    }
}
