import Foundation
import Testing
@testable import Clip_Builder

struct LastPlanRecordTests {
    @Test func keepsWholePromptAttachmentsAndRetry() throws {
        let temp = try TempDirectory()
        let library = LearnedLibrary(root: temp.url)
        let long = String(repeating: "x", count: 5_000)
        let record = LastPlanRecord(profile: "Brand", capturedAt: Date(), attempts: [
            .init(prompt: long, frames: ["TASTE EXAMPLE 1", "TASTE EXAMPLE 2"], requestedAt: Date(), provider: "codex", model: "m"),
            .init(prompt: long + "retry", frames: ["TASTE EXAMPLE 1"], requestedAt: Date()),
        ], acceptedAttempt: 1)
        try record.save(library: library)
        let loaded = try #require(LastPlanRecord.load(profile: "Brand", library: library))
        #expect(loaded.attempts.count == 2)
        #expect(loaded.attempts[0].prompt.count == 5_000)
        #expect(loaded.attempts[0].frames == ["TASTE EXAMPLE 1", "TASTE EXAMPLE 2"])
        #expect(loaded.attempts[0].provider == "codex")
        #expect(loaded.accepted?.prompt.hasSuffix("retry") == true)
        #expect(library.documents().isEmpty)
    }
    @Test func profilesStayIsolated() throws {
        let temp = try TempDirectory()
        let library = LearnedLibrary(root: temp.url)
        try LastPlanRecord(profile: "A", capturedAt: Date(), attempts: [.init(prompt: "a", frames: [], requestedAt: Date())],
                           acceptedAttempt: 0).save(library: library)
        try LastPlanRecord(profile: "B", capturedAt: Date(), attempts: [.init(prompt: "b", frames: [], requestedAt: Date())],
                           acceptedAttempt: 0).save(library: library)
        #expect(LastPlanRecord.load(profile: "A", library: library)?.accepted?.prompt == "a")
        #expect(LastPlanRecord.load(profile: "B", library: library)?.accepted?.prompt == "b")
        #expect(LastPlanRecord.load(profile: "C", library: library) == nil)
        #expect(LastPlanRecord.url(profile: "A", library: library) != LastPlanRecord.url(profile: "B", library: library))
    }
}

struct LastPlanRecorderTests {
    struct Boom: Error {}
    @Test func retryAdoptedRejectedAndFailed() throws {
        var recorder = LastPlanRecorder(profile: "Brand")
        let first = recorder.begin(prompt: "first", frames: ["A"])
        recorder.answered(first, provider: "codex", model: "m")
        let retry = recorder.begin(prompt: "first + fix", frames: ["A"])
        recorder.answered(retry, provider: "codex", model: "m")
        recorder.accept(1)
        #expect(recorder.record.acceptedAttempt == 1)
        #expect(recorder.record.attempts.map(\.outcome) == [.answered, .answered])

        recorder.accept(0)
        #expect(recorder.record.accepted?.prompt == "first")

        var failing = LastPlanRecorder(profile: "Brand")
        let a = failing.begin(prompt: "p", frames: [])
        failing.failed(a, error: Boom())
        failing.accept(nil)
        if case .failed = failing.record.attempts[0].outcome {} else { Issue.record("expected failed") }
        #expect(failing.record.acceptedAttempt == nil)

        var cancelled = LastPlanRecorder(profile: "Brand")
        let c = cancelled.begin(prompt: "p", frames: [])
        cancelled.failed(c, error: CancellationError())
        #expect(cancelled.record.attempts[0].outcome == .cancelled)

        var stray = LastPlanRecorder(profile: "Brand")
        stray.accept(3)
        #expect(stray.record.acceptedAttempt == nil)
    }
    @Test func savedRecordSurvivesRoundTripWithOutcomes() throws {
        let temp = try TempDirectory()
        let library = LearnedLibrary(root: temp.url)
        var recorder = LastPlanRecorder(profile: "Brand")
        let a = recorder.begin(prompt: "p", frames: [])
        recorder.failed(a, error: Boom())
        try recorder.save(library: library)
        let loaded = try #require(LastPlanRecord.load(profile: "Brand", library: library))
        if case .failed = loaded.attempts[0].outcome {} else { Issue.record("expected failed outcome") }
        // Never part of what leaves the Mac.
        #expect(library.documents().isEmpty)
        let packed = temp.url.appendingPathComponent("bundle")
        _ = try LearnedResourceBundle.pack([], root: packed)
        #expect(!FileManager.default.fileExists(atPath: LastPlanRecord.url(profile: "Brand", library: LearnedLibrary(root: packed)).path))
    }
}

@MainActor struct LearnedPreviewOutcomeTests {
    struct Boom: Error {}
    @Test func failedAndSupersededAttemptsAreLabelled() {
        var recorder = LastPlanRecorder(profile: "Brand")
        let first = recorder.begin(prompt: "p", frames: [])
        recorder.failed(first, error: Boom())
        recorder.accept(nil)
        let failedFirst = recorder.record
        #expect(LearnedPreviewSheet.outcomeNote(failedFirst, failedFirst.attempts[0])?.hasPrefix("This request failed") == true)

        var both = LastPlanRecorder(profile: "Brand")
        let a = both.begin(prompt: "p", frames: [])
        both.answered(a, provider: "codex", model: nil)
        let b = both.begin(prompt: "p2", frames: [])
        both.failed(b, error: CancellationError())
        both.accept(0)
        let record = both.record
        #expect(LearnedPreviewSheet.outcomeNote(record, record.attempts[0]) == nil)
        #expect(LearnedPreviewSheet.outcomeNote(record, record.attempts[1]) == "This request was cancelled before it answered.")

        var rejected = LastPlanRecorder(profile: "Brand")
        let r0 = rejected.begin(prompt: "p", frames: [])
        rejected.answered(r0, provider: nil, model: nil)
        let r1 = rejected.begin(prompt: "p2", frames: [])
        rejected.answered(r1, provider: nil, model: nil)
        rejected.accept(0)
        #expect(LearnedPreviewSheet.outcomeNote(rejected.record, rejected.record.attempts[1]) == "Answered, but the plan from another attempt was used.")
    }
}
