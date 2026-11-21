import Foundation
import Speech

/// Turns a voice-over recording into caption text: on-device transcription
/// with word clocks, the user's corrections, and translation into the
/// caption language.
nonisolated enum VoiceOverTranscriber {
    /// The recording transcribed in `language` (a locale such as "pt-BR").
    /// Never throws: a failure is recorded on the take, which stays usable.
    @concurrent
    static func transcribe(_ take: VoiceTake, audio: URL, language: String) async -> VoiceTake {
        var take = take
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(take.id).wav")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try await FFmpeg.run(["-y", "-i", audio.path, "-vn", "-ac", "1", "-ar", "16000",
                                  "-c:a", "pcm_s16le", scratch.path], timeout: 120, mediaResource: .decoding)
            let wanted = Locale(identifier: language.isEmpty ? Locale.current.identifier : language)
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
                take.state = .failed
                return take
            }
            let segments = try await TranscriptionService.transcribeFile(audioURL: scratch, locale: locale)
            let words = segments.flatMap { $0.words ?? [] }
            take.text = segments.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            take.words = words.map { word in
                var word = word
                word.start = min(take.duration, max(0, word.start))
                word.end = min(take.duration, max(word.start, word.end))
                return word
            }
            take.language = ProjectLanguageResolver.languageCode(locale.identifier)
            take.state = take.text.isEmpty ? .empty : .done
        } catch {
            take.state = .failed
        }
        return take
    }

    /// The take with its caption text corrected. Words the correction kept
    /// keep their clocks; translations made from the old text are dropped,
    /// the ones the user corrected stay.
    static func corrected(_ take: VoiceTake, text: String) -> VoiceTake {
        let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text != take.text else { return take }
        var take = take
        let span = VoiceOverPlacement.speechSpan(of: take)
        take.words = TranscriptWordAlignment.realign(text: text, original: take.words, start: span.start, end: span.end)
            ?? VoiceOverPlacement.spread(text, start: span.start, end: span.end)
        take.text = text
        take.translations = take.translations.filter { $0.value.edited == true }
        if take.state != .pending { take.state = text.isEmpty ? .empty : .done }
        return take
    }

    /// The take with the caption text of one language corrected by hand.
    static func corrected(_ take: VoiceTake, translation text: String, language: String) -> VoiceTake {
        var take = take
        let code = ProjectLanguageResolver.languageCode(language)
        let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.isEmpty {
            take.translations[code] = nil
        } else if take.translations[code]?.text != text {
            take.translations[code] = VoiceTakeTranslation(text: text, edited: true)
        }
        return take
    }

    /// The takes that still need a translation into `target`.
    static func needingTranslation(_ takes: [VoiceTake], target: String) -> [VoiceTake] {
        let code = ProjectLanguageResolver.languageCode(target)
        return takes.filter {
            !$0.text.isEmpty && !$0.language.isEmpty && $0.language != code && $0.translations[code] == nil
        }
    }

    /// Translates the takes spoken in another language and saves the result.
    /// A failure leaves them captioned in the language they were spoken in.
    static func translateMissing(_ takes: [VoiceTake], target: String, ai: AIService, database: Database,
                                 log: @escaping @Sendable (String) -> Void = { _ in }) async -> [VoiceTake] {
        let missing = needingTranslation(takes, target: target)
        guard !missing.isEmpty else { return takes }
        let code = ProjectLanguageResolver.languageCode(target)
        do {
            let response = try await TranslationBatch.perform(texts: missing.map(\.text), language: target, ai: ai)
            let answers = TranslationBatch.parse(response.text, count: missing.count)
            var result = takes
            for (index, text) in answers {
                guard let position = result.firstIndex(where: { $0.id == missing[index].id }),
                      // Deleted or corrected while the request was out: leave it alone.
                      (try? await database.setVoiceTakeTranslation(id: missing[index].id, language: code, text: text,
                                                                   of: missing[index].text)) == true else { continue }
                result[position].translations[code] = VoiceTakeTranslation(text: text)
            }
            if answers.count < missing.count {
                log("Voice over: \(missing.count - answers.count) recording(s) kept their own language in the captions")
            }
            return result
        } catch {
            if error is CancellationError { return takes }
            log("Voice over: translation failed (\(error.localizedDescription)); captions use the spoken language")
            return takes
        }
    }
}
