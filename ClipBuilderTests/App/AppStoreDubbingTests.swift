import Foundation
import Testing
@testable import Clip_Builder

@MainActor @Suite("Builder dubbing", .serialized)
struct AppStoreDubbingTests {
    private func store() -> AppStore {
        let settings = AppSettings(), profile = Fixtures.brand(name: "DubTest")
        let store = AppStore(settings: settings, profiles: [profile], active: profile, ai: AIService(config: settings.ai))
        store.diagnosticLogSink = { _, _ in }
        store.builder.document = Fixtures.timelineDocument(clips: [Fixtures.timelineClip(sourceStart: 0, duration: 2)])
        return store
    }

    private nonisolated static var prepare: AppStore.PrepareDub {
        { document, settings, log in
            let clip = document.videoTrack[0]
            let row = TranscriptRow(id: 1, videoID: 1, language: settings.language, isTranslation: true,
                startTime: 0, endTime: 2, text: "Olá", originalText: nil, wordsJSON: nil, provider: nil, model: nil)
            return try await DubPreparation.synthesize(document: document, rows: [clip.uid: [row]], turns: [:], settings: settings,
                speech: .init(voices: { _ in [.init(identifier: "stub", language: "pt-BR", name: "Stub")] },
                              synthesize: { _, _, _ in URL(fileURLWithPath: "/tmp/stub.caf") }, duration: { _ in 1 }), log: log)
        }
    }

    private func finish(_ store: AppStore, id: UUID) async throws -> DubReview {
        for _ in 0..<400 {
            if !store.jobs.hasLiveTasks { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let job = try #require(store.jobs.items.first { $0.id == id })
        #expect(job.status == .done)
        guard case .dub(let review) = job.result else { throw ScriptError.invalid("Missing dub review") }
        return review
    }

    @Test func stubJobLeavesDocumentUntouchedUntilApply() async throws {
        let store = store()
        let before = store.builder.document
        let id = try #require(store.dubTimeline(language: "pt-BR", prepare: Self.prepare))
        let review = try await finish(store, id: id)
        #expect(store.builder.document == before)
        #expect(review.prepared.lines.first?.text == "Olá")
        #expect(store.applyDubReview(review, jobID: id, remember: false))
        #expect(store.builder.document.dub?.language == "pt-BR")
        #expect(store.builder.document.dubLines?.first?.audio == "stub.caf")
        #expect(store.builder.document.videoTrack == before.videoTrack)
    }

    @Test func cancelAndStaleReviewNeverChangeTheDocument() async throws {
        let store = store()
        let id = try #require(store.dubTimeline(language: "pt-BR", prepare: Self.prepare))
        let review = try await finish(store, id: id)
        store.cancelDubReview(review)
        #expect(store.builder.document.dub == nil)
        store.builder.document.videoTrack[0].startTime = 5
        #expect(!store.applyDubReview(review, jobID: id, remember: false))
        #expect(store.builder.document.dubLines == nil)
    }

    @Test func cancellingWizardReviewReleasesWaiter() async throws {
        let store = store()
        let prepared = try await Self.prepare(store.builder.document, .init(language: "pt-BR"), { _ in })
        let task = Task { try await store.dubReviews.review(prepared, projectID: nil, profileName: store.activeProfile.profileName) }
        for _ in 0..<400 {
            if !store.jobs.awaitingReview.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let job = try #require(store.jobs.awaitingReview.first)
        store.jobs.dismiss(job.id)
        do { _ = try await task.value; Issue.record("Dismiss should cancel the waiting render") }
        catch is CancellationError {} catch { Issue.record(error) }
    }
}
