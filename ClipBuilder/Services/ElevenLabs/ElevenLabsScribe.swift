import Foundation

/// ElevenLabs Scribe (speech to text): its models, its answer, and the pure
/// rules that turn the answer's flat word list into transcript lines.
nonisolated enum ElevenLabsScribe {
    static let provider = "elevenlabs"

    /// Newest first: the first is the one offered when only one is.
    enum Model: String, CaseIterable, Sendable, Identifiable {
        case v3 = "scribe_v3"
        case v2 = "scribe_v2"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .v3: "Scribe v3"
            case .v2: "Scribe v2"
            }
        }
    }

    /// POST /v1/speech-to-text, the fields this app reads.
    struct Response: Decodable, Sendable, Equatable {
        var languageCode: String?
        var text: String?
        var words: [Word]?

        struct Word: Decodable, Sendable, Equatable {
            var text: String
            /// word, spacing or audio_event.
            var type: String?
            var start: Double?
            var end: Double?
            var speakerID: String?
            var logprob: Double?

            enum CodingKeys: String, CodingKey {
                case text, type, start, end, logprob
                case speakerID = "speaker_id"
            }
        }

        enum CodingKeys: String, CodingKey {
            case text, words
            case languageCode = "language_code"
        }
    }

    /// Where a line may end, in seconds of speech.
    struct Limits: Sendable, Equatable {
        /// A silence this long always starts a new line.
        var gap = 1.5
        /// A finished sentence ends the line once the line is this long, so
        /// "Sure." does not get a row of its own.
        var sentence = 3.0
        /// A comma ends a line that has run this long without a sentence end.
        var clause = 12.0
        /// No line runs past this.
        var maximum = 20.0
    }

    /// Transcript lines from Scribe's words. A line ends when the speaker
    /// changes, at a long silence, after a sentence, or when it has run too
    /// long. Sound tags ("(laughter)") and untimed words are left out.
    static func segments(_ response: Response, limits: Limits = Limits()) -> [TranscriptSegment] {
        let all = response.words ?? []
        // Languages written without spaces come back with no spacing tokens.
        let separator = all.contains { $0.type == "spacing" } ? " " : ""
        var segments: [TranscriptSegment] = []
        var words: [TranscriptWord] = []
        var speaker: String?
        func flush() {
            guard let first = words.first, let last = words.last else { return }
            segments.append(TranscriptSegment(start: first.start, end: max(last.end, first.start),
                                              text: words.map(\.word).joined(separator: separator), words: words))
            words = []
        }
        for word in all where (word.type ?? "word") == "word" {
            // A word is one whitespace-free token: the editor pairs a line's words with its text that way.
            let text = word.text.components(separatedBy: .whitespacesAndNewlines).joined()
            guard !text.isEmpty, let start = word.start, let end = word.end, end >= start else { continue }
            if let first = words.first, let previous = words.last {
                let length = previous.end - first.start
                let speakerChanged = speaker != nil && word.speakerID != nil && speaker != word.speakerID
                if speakerChanged || start - previous.end >= limits.gap
                    || (endsSentence(previous.word) && length >= limits.sentence)
                    || (endsClause(previous.word) && length >= limits.clause)
                    || end - first.start > limits.maximum {
                    flush()
                }
            }
            if words.isEmpty || word.speakerID != nil { speaker = word.speakerID }
            words.append(TranscriptWord(word: text, start: start.rounded(toPlaces: 2), end: end.rounded(toPlaces: 2),
                                        // Exactly 1 is the user's "marked right".
                                        confidence: word.logprob.map { min(exp($0), 0.99) }))
        }
        flush()
        return segments
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last(where: { !"\"'”’)»".contains($0) }) else { return false }
        return ".!?…。！？".contains(last)
    }

    private static func endsClause(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ",;:，；：".contains(last)
    }

    /// Scribe answers with a two- or three-letter code ("pt", "por"); the
    /// library stores the two-letter one where the language has it.
    static func language(_ code: String?) -> String {
        guard let code = code?.trimmingCharacters(in: .whitespaces).lowercased(), !code.isEmpty else { return "" }
        return Locale.LanguageCode(code).identifier(.alpha2) ?? code
    }

    /// The language to hold Scribe to, as a two-letter code; nil = detect.
    static func languageHint(_ identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        return Locale(identifier: identifier).language.languageCode?.identifier(.alpha2)
    }

    /// Spelling hints Scribe accepts: at most 50 characters and five words
    /// each, none of its forbidden characters, no repeats. Capped at 100,
    /// past which ElevenLabs bills a minimum length.
    static func keyterms(_ candidates: [String], limit: Int = 100) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for candidate in candidates {
            let term = candidate.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            guard term.count >= 2, term.count <= 50, term.split(separator: " ").count <= 5,
                  !term.contains(where: { "<>{}[]\\".contains($0) }),
                  seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count == limit { break }
        }
        return terms
    }

    /// The ffmpeg arguments that pack the normalized audio for upload: mono
    /// 16 kHz AAC, about 29 MB an hour instead of the WAV's 115 MB.
    static func uploadArguments(source: String, output: String) -> [String] {
        ["-y", "-i", source, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "aac", "-b:a", "64k", output]
    }
}
