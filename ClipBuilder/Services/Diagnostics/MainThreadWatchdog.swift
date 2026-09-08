import Foundation
import OSLog

/// Catches main-thread stalls in the field and records what the process was
/// doing while stuck.
///
/// A dedicated thread posts a ping to the main queue and waits for it to come
/// back. When a ping is outstanding for longer than `sampleThreshold` the
/// watchdog runs the system `sample` tool against this process (still stuck
/// at that moment) and keeps the report under the diagnostics folder that bug
/// reports pick up. When the ping finally returns, one log line records how
/// long the main thread was gone and which sample file holds the stacks.
///
/// Event tracking (menus, window drags, live resizes) runs the main run loop
/// in a mode that does not drain the main queue, so pings sent during it are
/// discounted rather than reported as stalls.
nonisolated final class MainThreadWatchdog: @unchecked Sendable {
    struct Configuration: Sendable {
        /// How often a ping goes out.
        var pingInterval: TimeInterval = 0.1
        /// Stalls at least this long are logged.
        var logThreshold: TimeInterval = 0.5
        /// Stalls at least this long are sampled while still in progress.
        var sampleThreshold: TimeInterval = 1.0
        /// Seconds `sample` observes the process.
        var sampleSeconds: Int = 1
        /// Rate limit: a run of stalls yields one sample per this many seconds.
        var minimumSecondsBetweenSamples: TimeInterval = 20
        /// Oldest sample files beyond this count are deleted.
        var keepFiles = 8
        var samplePath = "/usr/bin/sample"
    }

    /// One stall the main thread came back from.
    struct Stall: Sendable {
        var duration: TimeInterval
        var sampleFile: URL?
    }

    static let shared = MainThreadWatchdog()

    /// One ping's life: sent, maybe discounted (event tracking), maybe
    /// sampled while outstanding, eventually returned. A returned ping whose
    /// sample is still being written is reported when the sample lands.
    private struct Ping {
        var sent: TimeInterval
        var discounted = false
        var sampling = false
        var sampleFile: URL?
        var returned: TimeInterval?
    }

    private let log = Logger(subsystem: "com.mokotti-solutions.clipbuilder", category: "watchdog")
    private let lock = NSLock()
    private var configuration = Configuration()
    private var directory: URL?
    private var thread: Thread?
    private var running = false
    private var ping: Ping?
    private var lastSampleAt: TimeInterval = -.infinity
    /// Called off the main thread once per stall that ended.
    private var onStall: (@Sendable (Stall) -> Void)?
    private var _sampleFiles: [URL] = []

    /// Every sample file written since launch, newest last (tests and the log).
    var sampleFiles: [URL] { lock.withLock { _sampleFiles } }

    /// Starts pinging. Samples land in `directory` (created on demand).
    func start(directory: URL, configuration: Configuration = Configuration(),
               onStall: @escaping @Sendable (Stall) -> Void) {
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "MainThreadWatchdog"
        thread.qualityOfService = .userInitiated
        let shouldStart: Bool = lock.withLock {
            guard !running else { return false }
            running = true
            self.directory = directory
            self.configuration = configuration
            self.onStall = onStall
            ping = nil
            self.thread = thread
            return true
        }
        if shouldStart { thread.start() }
    }

    func stop() {
        lock.withLock {
            running = false
            thread = nil
        }
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static let trackingMode = "NSEventTrackingRunLoopMode"

    /// The mode the main run loop is currently in, readable from any thread.
    private static var mainRunLoopMode: String? {
        CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { $0.rawValue as String }
    }

    private func loop() {
        while true {
            let (alive, interval) = lock.withLock { (running, configuration.pingInterval) }
            guard alive else { return }
            tick()
            Thread.sleep(forTimeInterval: interval)
        }
    }

    private enum Action { case send, sample, wait }

    private func tick() {
        let now = Self.uptime
        let action: Action = lock.withLock {
            guard let current = ping, current.returned == nil || current.sampling else {
                ping = Ping(sent: now)
                return .send
            }
            guard current.returned == nil else { return .wait }
            if Self.mainRunLoopMode == Self.trackingMode {
                ping?.discounted = true
                return .wait
            }
            let stalled = now - current.sent
            guard stalled >= configuration.sampleThreshold, !current.discounted, !current.sampling,
                  now - lastSampleAt >= configuration.minimumSecondsBetweenSamples else { return .wait }
            lastSampleAt = now
            ping?.sampling = true
            return .sample
        }
        switch action {
        case .send:
            DispatchQueue.main.async { [weak self] in self?.pong(sent: now) }
        case .sample:
            let file = takeSample()
            let report: Stall? = lock.withLock {
                if let file { _sampleFiles.append(file) }
                guard var current = ping else { return nil }
                current.sampling = false
                current.sampleFile = file
                // The main thread already came back: report now, with the sample.
                if let returned = current.returned {
                    ping = nil
                    return Stall(duration: returned - current.sent, sampleFile: file)
                }
                ping = current
                return nil
            }
            if let report { deliver(report) }
        case .wait:
            break
        }
    }

    private func pong(sent: TimeInterval) {
        let now = Self.uptime
        let report: Stall? = lock.withLock {
            guard running, var current = ping, current.sent == sent else { return nil }
            current.returned = now
            if current.sampling {
                // The sample finishes on the watchdog thread and reports then.
                ping = current
                return nil
            }
            ping = nil
            let duration = now - sent
            guard !current.discounted, duration >= configuration.logThreshold else { return nil }
            return Stall(duration: duration, sampleFile: current.sampleFile)
        }
        if let report { deliver(report) }
    }

    private func deliver(_ stall: Stall) {
        let handler = lock.withLock { onStall }
        DispatchQueue.global(qos: .utility).async { handler?(stall) }
    }

    /// Runs `sample` against this process and returns the report's URL, or nil
    /// when the tool is missing, refused, or wrote nothing.
    private func takeSample() -> URL? {
        let (directory, configuration) = lock.withLock { (self.directory, self.configuration) }
        guard let directory else { return nil }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.stamp(Date())
        let file = directory.appendingPathComponent("hang-\(stamp).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.samplePath)
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "\(configuration.sampleSeconds)",
                             "-mayDie", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("sample could not start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let size = try? manager.attributesOfItem(atPath: file.path)[.size] as? Int, size > 0 else {
            log.error("sample failed with status \(process.terminationStatus)")
            try? manager.removeItem(at: file)
            return nil
        }
        prune(directory: directory, keep: configuration.keepFiles)
        return file
    }

    /// Delete the oldest `hang-*.txt` beyond `keep`.
    private func prune(directory: URL, keep: Int) {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return }
        let samples = urls.filter { $0.lastPathComponent.hasPrefix("hang-") && $0.pathExtension == "txt" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
        for stale in samples.dropFirst(keep) { try? manager.removeItem(at: stale) }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
