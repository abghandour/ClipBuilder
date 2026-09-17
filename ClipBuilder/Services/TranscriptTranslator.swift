import Foundation
import Translation

/// Caption translation for one video: Apple's on-device Translation first,
/// the configured AI provider for whatever it could not do. Shared by
/// Transcript Tools (on demand) and the automatic translation that runs
/// after a transcript lands when Settings names a language.
@MainActor
enum TranscriptTranslator {
    struct Outcome: Sendable {
        var segments: Int
        var summary: String
    }

    /// The video's original-language rows, oldest cut first.
    static func originals(videoID: Int64, database: Database) async throws -> [TranscriptRow] {
        try await database.fetchTranscripts(videoID: videoID).filter { !$0.isTranslation }
    }

    static func hasTranslation(videoID: Int64, language: String, database: Database) async -> Bool {
        ((try? await database.fetchTranscripts(videoID: videoID)) ?? [])
            .contains { $0.isTranslation && $0.language == language }
    }

    /// A session configuration for translating the video's transcript.
    static func configuration(originals: [TranscriptRow], target: String) -> TranslationSession.Configuration {
        let source = originals.first.map { Locale.Language(identifier: $0.language) }
        return TranslationSession.Configuration(source: source, target: Locale.Language(identifier: target))
    }

    /// Translate on device; rows the session could not translate go to the
    /// AI provider when the batch fallback is enabled, and the whole set
    /// goes there when the session itself is unavailable.
    ///
    /// `database` is the one the rows came from; it defaults to the store's
    /// current one for on-demand use.
    static func translate(videoID: Int64, originals: [TranscriptRow], target: String,
                          session: TranslationSession, store: AppStore,
                          database: Database? = nil) async throws -> Outcome {
        guard let database = database ?? store.database else { throw ScriptError.invalid("No profile database is open.") }
        let batchFallback = OnDevicePolicy.isEnabled(item: "translation-batch", config: store.settings.ai)
        do {
            try await session.prepareTranslation()
            let requests = originals.map {
                TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id))
            }
            let responses = try await session.translations(from: requests)
            let translated = Dictionary(uniqueKeysWithValues: responses.compactMap { response in
                response.clientIdentifier.map { ($0, response.targetText) }
            })
            let segments = originals.compactMap { row -> TranscriptSegment? in
                guard let text = translated[String(row.id)] else { return nil }
                return TranscriptSegment(start: row.startTime, end: row.endTime, text: text, words: nil)
            }
            let missing = originals.filter { translated[String($0.id)] == nil }
            if batchFallback, !missing.isEmpty {
                return try await translateWithAI(videoID: videoID, originals: missing, target: target,
                                                 existing: segments, store: store, database: database)
            }
            try await database.replaceTranscripts(videoID: videoID, language: target, isTranslation: true,
                                                  segments: segments, provider: "apple", model: "Translation")
            store.appendLog(\.pipelineLog, ["Translation answered by Apple Translation"])
            return Outcome(segments: segments.count,
                           summary: "Translated \(segments.count) segments to \(target) on device.")
        } catch {
            return try await translateWithAI(videoID: videoID, originals: originals, target: target,
                                             store: store, database: database)
        }
    }

    /// The AI provider's translation, merged with anything the device
    /// already translated — and, for rows the provider left unanswered,
    /// with the captions already stored in that language, so a partial
    /// answer never erases a caption track.
    static func translateWithAI(videoID: Int64, originals: [TranscriptRow], target: String,
                                existing: [TranscriptSegment] = [], store: AppStore, database: Database) async throws -> Outcome {
        let batchFallback = OnDevicePolicy.isEnabled(item: "translation-batch", config: store.settings.ai)
        var segments: [TranscriptSegment] = []
        var provenance: AIProvenance?
        if batchFallback {
            let response = try await TranslationBatch.perform(texts: originals.map(\.text), language: target, ai: store.ai)
            provenance = response.provenance
            let translated = TranslationBatch.parse(response.text, count: originals.count)
            segments = originals.enumerated().compactMap { index, row in
                guard let text = translated[index] else { return nil }
                return TranscriptSegment(start: row.startTime, end: row.endTime, text: text, words: nil)
            }
            store.appendLog(\.pipelineLog, ["Translation fallback answered by model in one batch"])
        } else {
            for row in originals {
                let response = try await store.ai.call(
                    prompt: "Translate this caption to \(target). Preserve names and meaning. Return only the translation:\n\(row.text)",
                    task: "translate", timeout: 60, log: { _ in })
                provenance = response.provenance
                segments.append(.init(start: row.startTime, end: row.endTime,
                                      text: response.text.trimmingCharacters(in: .whitespacesAndNewlines), words: nil))
            }
            store.appendLog(\.pipelineLog, ["Translation fallback answered by model per row"])
        }
        let answered = existing + segments
        let kept = try await database.fetchTranscripts(videoID: videoID)
            .filter { row in
                row.isTranslation && row.language == target
                    && !answered.contains { $0.start == row.startTime && $0.end == row.endTime }
            }
            .map { TranscriptSegment(start: $0.startTime, end: $0.endTime, text: $0.text, words: nil) }
        let merged = (answered + kept).sorted { $0.start < $1.start }
        try await database.replaceTranscripts(videoID: videoID, language: target, isTranslation: true,
                                              segments: merged, provider: provenance?.provider ?? "ai",
                                              model: provenance?.model,
                                              technique: existing.isEmpty
                                                  ? (batchFallback ? "numbered-translation-batch" : nil)
                                                  : "apple-translation")
        return Outcome(segments: merged.count,
                       summary: "Translated \(merged.count) segments to \(target) (\(segments.count) by the AI provider).")
    }
}
