import Foundation
import Testing
@testable import Clip_Builder

/// Blocks the real main thread, so this suite must not share it with others.
@Suite("Main thread watchdog", .serialized)
struct MainThreadWatchdogTests {
    private final class StallBox: @unchecked Sendable {
        let lock = NSLock()
        var stalls: [MainThreadWatchdog.Stall] = []
        func append(_ stall: MainThreadWatchdog.Stall) { lock.withLock { stalls.append(stall) } }
        var all: [MainThreadWatchdog.Stall] { lock.withLock { stalls } }
    }

    @Test("A blocked main thread is sampled while stuck and reported when it returns")
    func samplesAStall() async throws {
        let temp = try TempDirectory(prefix: "Watchdog")
        let box = StallBox()
        let watchdog = MainThreadWatchdog()
        var configuration = MainThreadWatchdog.Configuration()
        configuration.pingInterval = 0.05
        configuration.logThreshold = 0.2
        configuration.sampleThreshold = 0.4
        configuration.sampleSeconds = 1
        configuration.minimumSecondsBetweenSamples = 0
        watchdog.start(directory: temp.url, configuration: configuration) { box.append($0) }
        defer { watchdog.stop() }

        // Let the first ping round-trip so the stall is measured from a clean state.
        try await Task.sleep(for: .milliseconds(200))
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 1.6) }
        // The sample itself takes ~1 s and only starts after the threshold.
        try await Task.sleep(for: .seconds(4))

        // Other suites share the main thread, so shorter stalls of theirs can
        // be reported around ours; the one that crossed the sample threshold
        // is the one that matters.
        let stall = try #require(box.all.first { $0.sampleFile != nil })
        #expect(stall.duration >= configuration.sampleThreshold)
        let file = try #require(stall.sampleFile)
        #expect(file.lastPathComponent.hasPrefix("hang-"))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("Call graph") || text.contains("Thread"))
        #expect(watchdog.sampleFiles.contains(file))
    }

    @Test("Short stalls below the log threshold are not reported")
    func ignoresShortStalls() async throws {
        let temp = try TempDirectory(prefix: "Watchdog")
        let box = StallBox()
        let watchdog = MainThreadWatchdog()
        var configuration = MainThreadWatchdog.Configuration()
        configuration.pingInterval = 0.05
        configuration.logThreshold = 0.5
        configuration.sampleThreshold = 1.0
        watchdog.start(directory: temp.url, configuration: configuration) { box.append($0) }
        defer { watchdog.stop() }

        try await Task.sleep(for: .milliseconds(200))
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.15) }
        try await Task.sleep(for: .seconds(1))
        #expect(box.all.isEmpty)
        #expect(watchdog.sampleFiles.isEmpty)
    }
}
