import Foundation
import Translation

/// Caption translation for one video: Apple's on-device Translation first,
/// the configured AI provider for whatever it could not do. Shared by
/// Transcript Tools (on demand) and the automatic translation that runs
/// after a transcript lands when Settings names a language.
@MainActor
enum TranscriptTranslator {
    nonisolated struct Outcome: Sendable {
        var segments: Int
        var summary: String
    }

    typealias InstalledTranslation = @Sendable ([TranscriptRow], String) async throws -> [Int64: String]

    /// A view-less session can use installed pairs without prompting for downloads.
    /// Keep partial responses if the device fails partway through a batch.
    nonisolated static func translateInstalled(originals: [TranscriptRow], target: String) async throws -> [Int64: String] {
        var translated: [Int64: String] = [:]
        if #available(macOS 26.0, *) {
            for (language, rows) in Dictionary(grouping: originals, by: \.language) {
                try Task.checkCancellation()
                let source = Locale.Language(identifier: language)
                let targetLanguage = Locale.Language(identifier: target)
                guard await LanguageAvailability().status(from: source, to: targetLanguage) == .installed else { continue }
                try Task.checkCancellation()
                let session = TranslationSession(installedSource: source, target: targetLanguage)
                defer { session.cancel() }
                do {
                    let requests = rows.map {
                        TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id))
                    }
                    for try await response in session.translate(batch: requests) {
                        try Task.checkCancellation()
                        guard let identifier = response.clientIdentifier, let id = Int64(identifier) else { continue }
                        let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { translated[id] = text }
                    }
                } catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                    // Only unanswered rows go to the AI fallback.
                }
            }
        }
        try Task.checkCancellation()
        return translated
    }

    /// Wizard translation is always bounded, independent of the Transcript sheet's
    /// policy. Finish all chunks before replacing the target track once.
    nonisolated static func translateBatched(videoID: Int64, originals: [TranscriptRow], target: String,
                                             ai: AIService, database: Database, batchSize: Int = 25,
                                             timeout: TimeInterval = 120,
                                             onDevice: InstalledTranslation = translateInstalled,
                                             log: @Sendable (String) async -> Void = { _ in }) async throws -> Outcome {
        try Task.checkCancellation()
        guard !originals.isEmpty else { return Outcome(segments: 0, summary: "") }
        let size = max(1, batchSize)
        var answered: [Int64: String] = [:]
        var provenance: AIProvenance?
        var fallbackCount = 0
        for offset in stride(from: 0, to: originals.count, by: size) {
            try Task.checkCancellation()
            let chunk = Array(originals[offset..<min(offset + size, originals.count)])
            do {
                let local = try await onDevice(chunk, target)
                for row in chunk {
                    if let text = local[row.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        answered[row.id] = text
                    }
                }
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
            }
            let missing = chunk.filter { answered[$0.id] == nil }
            if !missing.isEmpty {
                try Task.checkCancellation()
                do {
                    let response = try await TranslationBatch.perform(texts: missing.map(\.text), language: target,
                                                                      ai: ai, timeout: timeout)
                    provenance = response.provenance
                    for (index, text) in TranslationBatch.parse(response.text, count: missing.count) {
                        answered[missing[index].id] = text
                    }
                } catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                    await log("Captions: translation batch failed (\(error.userMessage)); retrying unanswered lines")
                }
                // Retry each unanswered row once, in batches smaller than the first request.
                let retry = missing.filter { answered[$0.id] == nil }
                let retrySize = max(1, missing.count / 2)
                for retryOffset in stride(from: 0, to: retry.count, by: retrySize) {
                    try Task.checkCancellation()
                    let rows = Array(retry[retryOffset..<min(retryOffset + retrySize, retry.count)])
                    do {
                        let response = try await TranslationBatch.perform(texts: rows.map(\.text), language: target,
                                                                          ai: ai, timeout: timeout)
                        provenance = response.provenance
                        for (index, text) in TranslationBatch.parse(response.text, count: rows.count) {
                            answered[rows[index].id] = text
                        }
                    } catch {
                        if error is CancellationError { throw error }
                        try Task.checkCancellation()
                        await log("Captions: translation retry failed (\(error.userMessage))")
                    }
                }
            }
            try Task.checkCancellation()
            fallbackCount += chunk.count(where: { answered[$0.id] == nil })
            await log("Captions: translated \(offset + chunk.count) of \(originals.count) lines")
        }
        try Task.checkCancellation()
        let stored = try await database.fetchTranscripts(videoID: videoID)
            .filter { $0.isTranslation && $0.language == target }
        // An unanswered row must not overwrite an already stored translation.
        let segments = originals.compactMap { row -> TranscriptSegment? in
            if answered[row.id] == nil,
               stored.contains(where: { $0.startTime == row.startTime && $0.endTime == row.endTime }) { return nil }
            return TranscriptSegment(start: row.startTime, end: row.endTime, text: answered[row.id] ?? row.text, words: nil)
        }
        let kept = stored.filter { row in
            !segments.contains { $0.start == row.startTime && $0.end == row.endTime }
        }.map { TranscriptSegment(start: $0.startTime, end: $0.endTime, text: $0.text, words: nil) }
        try Task.checkCancellation()
        try await database.replaceTranscripts(videoID: videoID, language: target, isTranslation: true,
            segments: (segments + kept).sorted { $0.start < $1.start },
            provider: provenance?.provider ?? (answered.isEmpty ? "original" : "apple"), model: provenance?.model,
            technique: "numbered-translation-batch")
        if fallbackCount > 0 {
            await log("Captions: could not translate \(fallbackCount) lines — keeping stored captions or using the original language")
        }
        return Outcome(segments: originals.count,
                       summary: "Prepared \(originals.count) caption lines to \(target).")
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
            if error is CancellationError { throw error }
            try Task.checkCancellation()
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
        try await translate(videoID: videoID, originals: originals, target: target,
                            existing: existing, ai: store.ai, database: database,
                            log: { await store.appendLog(\.pipelineLog, [$0]) })
    }

    /// Background jobs have no view-owned Apple Translation session. Reuse the
    /// Transcript sheet's AI fallback, including its configured `.translate` route.
    nonisolated static func translate(videoID: Int64, originals: [TranscriptRow], target: String,
                                      existing: [TranscriptSegment] = [], ai: AIService, database: Database,
                                      log: @Sendable (String) async -> Void = { _ in }) async throws -> Outcome {
        try Task.checkCancellation()
        let batchFallback = OnDevicePolicy.isEnabled(item: "translation-batch", config: await ai.config)
        var segments: [TranscriptSegment] = []
        var provenance: AIProvenance?
        if batchFallback {
            let response = try await TranslationBatch.perform(texts: originals.map(\.text), language: target, ai: ai)
            provenance = response.provenance
            let translated = TranslationBatch.parse(response.text, count: originals.count)
            segments = originals.enumerated().compactMap { index, row in
                guard let text = translated[index] else { return nil }
                return TranscriptSegment(start: row.startTime, end: row.endTime, text: text, words: nil)
            }
            await log("Translation fallback answered by model in one batch")
        } else {
            for row in originals {
                try Task.checkCancellation()
                let response = try await ai.call(
                    prompt: "Translate this caption to \(target). Preserve names and meaning. Return only the translation:\n\(row.text)",
                    task: .translate, timeout: 60, log: { _ in })
                provenance = response.provenance
                segments.append(.init(start: row.startTime, end: row.endTime,
                                      text: response.text.trimmingCharacters(in: .whitespacesAndNewlines), words: nil))
            }
            await log("Translation fallback answered by model per row")
        }
        try Task.checkCancellation()
        guard !segments.isEmpty || !existing.isEmpty else {
            throw AIError.unusableResponse("The translator returned no caption lines.")
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
