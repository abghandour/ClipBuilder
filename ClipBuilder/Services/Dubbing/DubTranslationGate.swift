import Foundation

/// Preparation for the future dub job. No view or AppStore state is needed.
/// Each call owns one video's source ranges and captured transcription set.
nonisolated enum DubTranslationGate {
    @concurrent
    static func ensure(videoID: Int64, file: String, ranges: [Range<Double>], language: String,
                       ai: AIService, database: Database,
                       onDevice: TranscriptTranslator.InstalledTranslation = TranscriptTranslator.translateInstalled,
                       log: @Sendable (String) async -> Void = { _ in }) async throws -> [TranscriptRow] {
        try Task.checkCancellation()
        guard !ranges.isEmpty else { return [] }
        let rows = try await database.fetchTranscripts(videoID: videoID)
        func inRange(_ row: TranscriptRow) -> Bool {
            ranges.contains { row.startTime < $0.upperBound && row.endTime > $0.lowerBound }
        }
        let originals = rows.filter { !$0.isTranslation && inRange($0) }
        let key = originals.first?.transcriptionKey ?? rows.first?.transcriptionKey
        func translations(_ rows: [TranscriptRow]) -> [TranscriptRow] {
            rows.filter {
                $0.isTranslation && $0.language == language && $0.provider != "original"
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && inRange($0)
            }
        }
        func missing(from translated: [TranscriptRow]) -> [TranscriptRow] {
            originals.filter { original in
                !translated.contains { $0.startTime <= original.startTime && $0.endTime >= original.endTime }
            }
        }
        let existing = translations(rows)
        let needed = missing(from: existing)
        if needed.isEmpty, !existing.isEmpty { return existing }
        do {
            let installed: [Int64: String]
            do {
                installed = try await onDevice(needed, language)
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                installed = [:]
            }
            // Installed Apple Translation first; the batched translator then
            // reuses those answers and sends only missing rows to .translate.
            _ = try await TranscriptTranslator.translateBatched(videoID: videoID, originals: needed,
                target: language, ai: ai, database: database, onDevice: { _, _ in installed },
                allowOriginalFallback: false, log: log)
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            throw failure(language: language, file: file)
        }
        try Task.checkCancellation()
        let translated = translations(try await database.fetchTranscripts(videoID: videoID, transcriptionKey: key))
        guard !translated.isEmpty, missing(from: translated).isEmpty else {
            throw failure(language: language, file: file)
        }
        return translated
    }

    static func failure(language: String, file: String) -> ScriptError {
        .invalid("No \(language) translation for \(file); translate the transcript first")
    }
}
