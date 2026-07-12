import Foundation

nonisolated struct ProcessResult: Sendable {
    var stdout: Data
    var stderr: Data
    var exitCode: Int32

    var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
}

nonisolated enum ProcessRunnerError: Error, CustomStringConvertible {
    case launchFailed(String, underlying: String)
    case timedOut(String)

    var description: String {
        switch self {
        case .launchFailed(let tool, let underlying): return "Could not launch \(tool): \(underlying)"
        case .timedOut(let tool): return "\(tool) timed out"
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Cross-thread state for one process run, shared between the worker thread,
/// the timeout work item, and the Task cancellation handler. Everything goes
/// through the lock — `timedOut`/`cancelled` are written from other queues
/// while the worker reads them after waitUntilExit.
nonisolated private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var timedOut = false
    private var cancelled = false

    /// Record the process about to launch; returns false (don't launch) if
    /// the task was cancelled while queued.
    func claimLaunch(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    /// Mark cancelled; returns the process to signal if it already launched.
    func markCancelled() -> Process? {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        return process
    }

    func markTimedOut() {
        lock.lock()
        defer { lock.unlock() }
        timedOut = true
    }

    var flags: (timedOut: Bool, cancelled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (timedOut, cancelled)
    }
}

/// Runs external tools (ffmpeg, ffprobe, claude, gemini, codex) off the main
/// actor, with full stdout/stderr capture and an optional timeout.
nonisolated enum ProcessRunner {
    static func run(executable: URL,
                    arguments: [String],
                    stdin: Data? = nil,
                    timeout: TimeInterval? = nil,
                    environment: [String: String]? = nil) async throws -> ProcessResult {
        let toolName = executable.lastPathComponent
        let state = ProcessRunState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    if let environment {
                        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                    }

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    let stdinPipe: Pipe? = stdin != nil ? Pipe() : nil
                    if let stdinPipe { process.standardInput = stdinPipe }

                    guard state.claimLaunch(process) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: ProcessRunnerError.launchFailed(
                            toolName, underlying: error.localizedDescription))
                        return
                    }
                    // Cancellation can slip in between claimLaunch and run(),
                    // when there was no live process to signal yet.
                    if state.flags.cancelled { terminate(process) }

                    if let stdin, let stdinPipe {
                        DispatchQueue.global(qos: .userInitiated).async {
                            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                            try? stdinPipe.fileHandleForWriting.close()
                        }
                    }

                    let outBox = DataBox()
                    let errBox = DataBox()
                    let readGroup = DispatchGroup()
                    readGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        outBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }
                    readGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        errBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }

                    var timeoutWork: DispatchWorkItem?
                    if let timeout {
                        let work = DispatchWorkItem {
                            if process.isRunning {
                                state.markTimedOut()
                                terminate(process)
                            }
                        }
                        timeoutWork = work
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
                    }

                    process.waitUntilExit()
                    timeoutWork?.cancel()
                    readGroup.wait()

                    let flags = state.flags
                    if flags.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if flags.timedOut {
                        continuation.resume(throwing: ProcessRunnerError.timedOut(toolName))
                    } else {
                        continuation.resume(returning: ProcessResult(
                            stdout: outBox.data, stderr: errBox.data,
                            exitCode: process.terminationStatus))
                    }
                }
            }
        } onCancel: {
            if let process = state.markCancelled() {
                terminate(process)
            }
        }
    }

    /// SIGTERM with a SIGKILL escalation if it's ignored (ffmpeg mid-encode).
    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private static let locateLock = NSLock()
    nonisolated(unsafe) private static var locateCache: [String: URL] = [:]
    nonisolated(unsafe) private static var locateMisses: [String: Date] = [:]
    /// The login-shell fallback in locateUncached is expensive (sources the
    /// user's dotfiles), so misses are cached too — briefly, so a tool
    /// installed mid-session is still picked up within a minute.
    private static let missTTL: TimeInterval = 60

    /// Locate a command-line tool: absolute path as-is, then Homebrew and
    /// standard prefixes, then a `which` lookup through the login shell PATH.
    static func locate(_ tool: String) -> URL? {
        locateLock.lock()
        let cached = locateCache[tool]
        let missedAt = locateMisses[tool]
        locateLock.unlock()
        if let cached { return cached }
        if let missedAt, Date().timeIntervalSince(missedAt) < missTTL { return nil }
        let located = locateUncached(tool)
        locateLock.lock()
        if let located {
            locateCache[tool] = located
            locateMisses[tool] = nil
        } else {
            locateMisses[tool] = Date()
        }
        locateLock.unlock()
        return located
    }

    private static func locateUncached(_ tool: String) -> URL? {
        if tool.hasPrefix("/") || tool.hasPrefix("~") {
            let expanded = (tool as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded)
                ? URL(fileURLWithPath: expanded) : nil
        }
        let prefixes = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/local/bin"]
        for prefix in prefixes {
            let candidate = "\(prefix)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        // Node-based CLIs (claude, gemini, codex) often live in nvm/npm dirs
        // that only the login shell knows about.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
