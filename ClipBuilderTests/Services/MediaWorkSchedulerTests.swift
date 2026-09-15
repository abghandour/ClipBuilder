import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

nonisolated enum MediaSchedulingChecks {
    static func hold(_ scheduler: MediaWorkScheduler, _ resource: MediaWorkScheduler.Resource,
                     priority: MediaWorkScheduler.Priority = MediaWorkScheduler.priority) -> (task: Task<Void, Error>, release: AsyncStream<Void>.Continuation) {
        let (stream, release) = AsyncStream<Void>.makeStream()
        let task = Task {
            let permit = try await scheduler.acquire(resource, priority: priority)
            defer { withExtendedLifetime(permit) {} }
            for await _ in stream { }
        }
        return (task, release)
    }

    static func wait(_ scheduler: MediaWorkScheduler, _ resource: MediaWorkScheduler.Resource,
                     active: Int? = nil, waiting: Int? = nil) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let state = await scheduler.snapshot(resource)
            if (active == nil || state.active == active) && (waiting == nil || state.waiting == waiting) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let state = await scheduler.snapshot(resource)
        try #require((active == nil || state.active == active) && (waiting == nil || state.waiting == waiting),
                     "Timed out waiting for \(resource): active=\(state.active), waiting=\(state.waiting)")
    }
}

struct MediaWorkSchedulerTests {
    @Test func requestedWorkOvertakesPrefetchButBackgroundMakesProgress() async throws {
        let scheduler = MediaWorkScheduler(encoding: 1, maxInteractiveBurst: 4)
        var held: MediaWorkScheduler.Permit? = try await scheduler.acquire(.encoding)
        #expect(held != nil)
        let order = Mutex<[String]>([])
        var jobs: [Task<Void, Error>] = []
        defer { held = nil; jobs.forEach { $0.cancel() } }
        for (index, priority) in ([MediaWorkScheduler.Priority.background] + Array(repeating: .interactive, count: 6)).enumerated() {
            jobs.append(Task {
                let permit = try await scheduler.acquire(.encoding, priority: priority)
                defer { withExtendedLifetime(permit) {} }
                order.withLock { $0.append(index == 0 ? "background" : "interactive") }
            })
            try await MediaSchedulingChecks.wait(scheduler, .encoding, active: 1, waiting: index + 1)
        }
        held = nil
        for job in jobs { try await job.value }
        #expect(order.withLock { $0 } == ["interactive", "interactive", "interactive", "interactive", "background", "interactive", "interactive"])
        try await MediaSchedulingChecks.wait(scheduler, .encoding, active: 0, waiting: 0)
    }

    @Test func decodeReserveCountsBackgroundWorkOnly() async throws {
        let scheduler = MediaWorkScheduler(decoding: 2)
        var background: MediaWorkScheduler.Permit? = try await scheduler.acquire(.decoding)
        #expect(background != nil)
        let queued = MediaSchedulingChecks.hold(scheduler, .decoding)
        defer { queued.task.cancel(); queued.release.finish(); background = nil }
        try await MediaSchedulingChecks.wait(scheduler, .decoding, active: 1, waiting: 1)
        var interactive: MediaWorkScheduler.Permit? = try await scheduler.acquire(.decoding, priority: .interactive)
        #expect(interactive != nil)
        try await MediaSchedulingChecks.wait(scheduler, .decoding, active: 2, waiting: 1)
        background = nil
        // The next background decoder can fill the vacated slot even while
        // interactive work still occupies its reserved slot.
        try await MediaSchedulingChecks.wait(scheduler, .decoding, active: 2, waiting: 0)
        queued.release.finish()
        try await queued.task.value
        interactive = nil
        try await MediaSchedulingChecks.wait(scheduler, .decoding, active: 0, waiting: 0)
    }

    @Test func queuedCancellationAndAdmissionRacesDoNotLeakCapacity() async throws {
        let scheduler = MediaWorkScheduler(encoding: 1)
        for index in 0..<30 {
            var held: MediaWorkScheduler.Permit? = try await scheduler.acquire(.encoding)
            #expect(held != nil)
            let queued = Task {
                let permit = try await scheduler.acquire(.encoding)
                withExtendedLifetime(permit) {}
            }
            defer { queued.cancel(); held = nil }
            try await MediaSchedulingChecks.wait(scheduler, .encoding, active: 1, waiting: 1)
            if index.isMultiple(of: 2) {
                queued.cancel()
                try await MediaSchedulingChecks.wait(scheduler, .encoding, active: 1, waiting: 0)
                held = nil
            } else {
                held = nil
                queued.cancel()
            }
            do { try await queued.value } catch is CancellationError { }
            try await MediaSchedulingChecks.wait(scheduler, .encoding, active: 0, waiting: 0)
        }
    }

    @Test func processDefaultsAreConservative() {
        #expect(ProcessRunner.mediaResource(for: URL(filePath: "/usr/local/bin/ffprobe")) == .probing)
        #expect(ProcessRunner.mediaResource(for: URL(filePath: "/usr/local/bin/ffmpeg")) == .encoding)
        #expect(ProcessRunner.mediaResource(for: URL(filePath: "/bin/echo")) == nil)
    }

    @Test func childWorkInheritsInteractivePriorityAndScheduler() async throws {
        let scheduler = MediaWorkScheduler(vision: 1)
        try await MediaWorkScheduler.$current.withValue(scheduler) {
            var held: MediaWorkScheduler.Permit? = try await scheduler.acquire(.vision)
            #expect(held != nil)
            let background = MediaSchedulingChecks.hold(MediaWorkScheduler.current, .vision)
            defer { held = nil; background.task.cancel(); background.release.finish() }
            try await MediaSchedulingChecks.wait(scheduler, .vision, waiting: 1)
            let requested = MediaWorkScheduler.$priority.withValue(.interactive) {
                MediaSchedulingChecks.hold(MediaWorkScheduler.current, .vision)
            }
            defer { requested.task.cancel(); requested.release.finish() }
            try await MediaSchedulingChecks.wait(scheduler, .vision, waiting: 2)
            held = nil
            try await MediaSchedulingChecks.wait(scheduler, .vision, active: 1, waiting: 1)
            requested.release.finish()
            try await requested.task.value
            try await MediaSchedulingChecks.wait(scheduler, .vision, active: 1, waiting: 0)
            background.release.finish()
            try await background.task.value
            try await MediaSchedulingChecks.wait(scheduler, .vision, active: 0, waiting: 0)
        }
    }
}
