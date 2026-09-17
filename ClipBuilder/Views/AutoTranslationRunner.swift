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
        let target = store.settings.podcast.autoTranslateLanguage
        guard !target.isEmpty else { store.autoTranslateQueue.removeAll(); return }
        while let database = store.database, let videoID = store.claimAutoTranslation() {
            let generation = store.profileGeneration
            if await TranscriptTranslator.hasTranslation(videoID: videoID, language: target, database: database) {
                store.finishAutoTranslation(videoID: videoID)
                continue
            }
            let originals = (try? await TranscriptTranslator.originals(videoID: videoID, database: database)) ?? []
            guard !originals.isEmpty, generation == store.profileGeneration else {
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
        defer {
            current = nil
            configuration = nil
        }
        // The profile changed while the session was coming up: the ids no
        // longer mean these videos, and the store dropped the queue.
        guard job.generation == store.profileGeneration else { return }
        let name = store.videos.first { $0.id == job.videoID }?.filename ?? "video \(job.videoID)"
        do {
            let outcome = try await TranscriptTranslator.translate(videoID: job.videoID, originals: job.originals,
                                                                   target: job.target, session: session,
                                                                   store: store, database: job.database)
            store.appendLog(\.analysisLog, ["\(name): \(outcome.summary)"])
        } catch {
            store.appendLog(\.analysisLog, ["\(name): automatic translation failed — \(error.userMessage)"])
        }
        store.finishAutoTranslation(videoID: job.videoID)
        await startNext()
    }
}
