import Foundation
import Synchronization
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

    @Test func updateRefitsChangedSpeakerAndVoiceLinesOnly() async throws {
        let store = store()
        let id = try #require(store.dubTimeline(language: "pt-BR", prepare: Self.prepare))
        let review = try await finish(store, id: id)
        var lines = review.prepared.lines
        var settings = review.prepared.settings
        // The one line moves from "unknown" to the guest; the guest gets the second voice.
        lines[0].speakerKey = "guest"
        settings.voices["guest"] = "second"
        let synthesized = Mutex<[String]>([])
        let speech = DubPreparation.Speech(
            voices: { _ in [.init(identifier: "stub", language: "pt-BR", name: "Stub"), .init(identifier: "second", language: "pt-BR", name: "Second")] },
            synthesize: { _, voice, _ in synthesized.withLock { $0.append(voice) }; return URL(fileURLWithPath: "/tmp/\(voice).caf") },
            duration: { _ in 1 })
        store.updateDubReview(review, jobID: id, lines: lines, settings: settings, speech: speech)
        let updated = try await finish(store, id: try #require(store.jobs.items.first { $0.title == "Update dub lines" }?.id))
        #expect(updated.prepared.lines[0].speakerKey == "guest" && updated.prepared.lines[0].voice == "second")
        #expect(updated.prepared.lines[0].audio == "second.caf")
        #expect(updated.prepared.settings.voices["guest"] == "second")
        #expect(synthesized.withLock { $0 } == ["second"])
        // Nothing changed: no synthesis, lines kept.
        synthesized.withLock { $0 = [] }
        store.updateDubReview(updated, jobID: id, lines: updated.prepared.lines, settings: updated.prepared.settings, speech: speech)
        let same = try await finish(store, id: try #require(store.jobs.items.last { $0.title == "Update dub lines" }?.id))
        #expect(same.prepared.lines == updated.prepared.lines && synthesized.withLock { $0 }.isEmpty)
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

extension AppStoreDubbingTests {
    private func waitForJobs(_ store: AppStore) async throws {
        for _ in 0..<400 {
            if !store.jobs.hasLiveTasks { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Dub job did not finish")
    }

    private func finalSpeech() -> DubPreparation.Speech {
        .init(voices: { _ in [] }, synthesize: { _, _, _ in URL(fileURLWithPath: "/tmp/final.caf") },
              duration: { _ in 1 })
    }

    @Test func applyingDraftRunsAsAJobAndCommitsFinalAudio() async throws {
        let store = store()
        let id = try #require(store.dubTimeline(language: "pt-BR", prepare: Self.prepare))
        var review = try await finish(store, id: id)
        review.prepared.lines[0].draft = true
        #expect(store.applyDubReview(review, jobID: id, remember: false, speech: finalSpeech()))
        #expect(store.builder.document.dub == nil)
        #expect(store.jobs.running.contains { $0.title == "Finalize dub" })
        try await waitForJobs(store)
        #expect(store.builder.document.dubLines?.first?.draft != true)
        #expect(store.builder.document.dubLines?.first?.audio == "final.caf")
    }

    @Test func wizardReceivesFinalLinesAfterApply() async throws {
        let store = store()
        var prepared = try await Self.prepare(store.builder.document, .init(language: "pt-BR"), { _ in })
        prepared.lines[0].draft = true
        let snapshot = prepared
        let waiting = Task { try await store.dubReviews.review(snapshot, projectID: nil, profileName: store.activeProfile.profileName) }
        for _ in 0..<400 {
            if !store.jobs.awaitingReview.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let job = try #require(store.jobs.awaitingReview.first)
        guard case .dub(let review) = job.result else { throw ScriptError.invalid("Missing Wizard review") }
        #expect(store.applyDubReview(review, jobID: job.id, remember: false, speech: finalSpeech()))
        let final = try await waiting.value
        #expect(final.lines[0].draft != true && final.lines[0].audio == "final.caf")
        try await waitForJobs(store)
    }

    @Test func stoppingFinalizationReleasesWizardWaiter() async throws {
        let store = store()
        var prepared = try await Self.prepare(store.builder.document, .init(language: "pt-BR"), { _ in })
        prepared.lines[0].draft = true
        let snapshot = prepared
        let waiting = Task { try await store.dubReviews.review(snapshot, projectID: nil, profileName: store.activeProfile.profileName) }
        for _ in 0..<400 {
            if !store.jobs.awaitingReview.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let job = try #require(store.jobs.awaitingReview.first)
        guard case .dub(let review) = job.result else { throw ScriptError.invalid("Missing Wizard review") }
        let speech = DubPreparation.Speech(voices: { _ in [] }, synthesize: { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return URL(fileURLWithPath: "/tmp/should-not-apply.caf")
        }, duration: { _ in 1 })
        #expect(store.applyDubReview(review, jobID: job.id, remember: false, speech: speech))
        let final = try #require(store.jobs.running.first { $0.title == "Finalize dub" })
        store.jobs.cancel(final.id)
        do { _ = try await waiting.value; Issue.record("Stop must release the render") }
        catch is CancellationError {} catch { Issue.record(error) }
        try await waitForJobs(store)
        #expect(store.builder.document.dub == nil)
    }

    @Test func timelineChangedDuringFinalizationIsNotOverwritten() async throws {
        let store = store()
        let id = try #require(store.dubTimeline(language: "pt-BR", prepare: Self.prepare))
        var review = try await finish(store, id: id)
        review.prepared.lines[0].draft = true
        #expect(store.applyDubReview(review, jobID: id, remember: false, speech: finalSpeech()))
        store.builder.document.videoTrack[0].startTime = 7
        try await waitForJobs(store)
        #expect(store.builder.document.dub == nil)
        #expect(store.builder.document.videoTrack[0].startTime == 7)
    }
}
