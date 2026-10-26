import SwiftUI
import Translation

/// Drains the store's automatic-translation queue: each queued video's
/// fresh transcript is translated on the Mac to the language Settings
/// names, one video at a time, in the background. Lives on the main
/// window because Apple's Translation sessions come from a view.
///
/// A job is claimed on the store before any wait (so a second runner, or a
/// second call here, never takes the same video) and stays bound to the
/// profile it started in: its rows are read from and written to that
/// profile's database, and a profile switch abandons it.
struct AutoTranslationRunner: ViewModifier {
    @Environment(AppStore.self) private var store
    @State private var configuration: TranslationSession.Configuration?
    @State private var current: Job?

    private struct Job {
        var videoID: Int64
        var originals: [TranscriptRow]
        var target: String
        var database: Database
        var generation: Int
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: store.autoTranslateQueue) { _, _ in Task { await startNext() } }
            .translationTask(configuration) { session in
                await run(session)
            }
            .onDisappear {
                if let job = current { store.releaseAutoTranslation(videoID: job.videoID) }
            }
    }

    private func startNext() async {
        guard current == nil else { return }
        let target = store.editingDefaults.podcast.autoTranslateLanguage
        guard !target.isEmpty else { store.autoTranslateQueue.removeAll(); return }
        while let database = store.database, let videoID = store.claimAutoTranslation() {
            let generation = store.profileGeneration
            let originals = (try? await TranscriptTranslator.originals(videoID: videoID, database: database)) ?? []
            guard !originals.isEmpty, generation == store.profileGeneration else {
                store.finishAutoTranslation(videoID: videoID)
                continue
            }
            if await TranscriptTranslator.hasTranslation(videoID: videoID, language: target,
                transcriptionKey: originals.first?.transcriptionKey, database: database) {
                store.finishAutoTranslation(videoID: videoID)
                continue
            }
            current = Job(videoID: videoID, originals: originals, target: target,
                          database: database, generation: generation)
            configuration = TranscriptTranslator.configuration(originals: originals, target: target)
            return
        }
    }

    private func run(_ session: TranslationSession) async {
        guard let job = current else { return }
        await translate(job, session: session)
        // Release the slot BEFORE looking for more work: startNext() is a
        // no-op while `current` is set, and queue changes that arrived during
        // this job were dropped by that same guard. Clearing `configuration`
        // ends this translation task, so the next claim runs in its own
        // task rather than inherit the cancellation.
        current = nil
        configuration = nil
        store.finishAutoTranslation(videoID: job.videoID)
        Task { await startNext() }
    }

    private func translate(_ job: Job, session: TranslationSession) async {
        // The profile changed while the session was coming up: the ids no
        // longer mean these videos, and the store dropped the queue.
        guard job.generation == store.profileGeneration else { return }
        let name = store.videos.first { $0.id == job.videoID }?.filename ?? "video \(job.videoID)"
        do {
            let outcome = try await TranscriptTranslator.translate(videoID: job.videoID, originals: job.originals,
                                                                   target: job.target, session: session,
                                                                   store: store, database: job.database)
            store.appendLog(\.analysisLog, ["\(name): \(outcome.summary)"])
            // A first translation may have started before the user saved an edit.
            // Now that the language exists, refresh any rows changed during that job.
            if job.generation == store.profileGeneration, let key = job.originals.first?.transcriptionKey {
                let currentRows = try await job.database.fetchTranscripts(videoID: job.videoID, transcriptionKey: key)
                guard job.generation == store.profileGeneration else { return }
                let sourceText = Dictionary(uniqueKeysWithValues: job.originals.map { ($0.id, $0.text) })
                // Same row, other text: an edit saved meanwhile. A re-cut
                // gives rows new ids and is not an edit.
                let changed = currentRows.filter { row in
                    guard !row.isTranslation, let before = sourceText[row.id] else { return false }
                    return before != row.text
                }.map(\.id)
                store.enqueueAutoTranslation(videoID: job.videoID, transcriptionKey: key, rowIDs: changed)
            }
        } catch {
            store.appendLog(\.analysisLog, ["\(name): automatic translation failed — \(error.userMessage)"])
        }
    }
}
