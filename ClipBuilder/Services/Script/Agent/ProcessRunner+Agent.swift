import Darwin
import Foundation

nonisolated private final class AgentProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

extension ProcessRunner {
    /// Opt-in process-group execution for agents. Existing ffmpeg/AI callers
    /// keep their capture semantics and login-shell PATH behavior unchanged.
    /// The environment is complete, never merged with the parent implicitly.
    nonisolated static func runAgent(executable: URL, arguments: [String], cwd: URL,
                                    environment: [String: String], timeout: TimeInterval,
                                    maximumOutputBytes: Int, stderrTailBytes: Int = 64 * 1024,
                                    stdout: @escaping @Sendable (Data) throws -> Void) async throws -> ProcessResult {
        let cancellation = AgentProcessCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try agentWorker(executable: executable, arguments: arguments,
                            cwd: cwd, environment: environment, timeout: timeout, maximumOutputBytes: maximumOutputBytes,
                            stderrTailBytes: stderrTailBytes, cancellation: cancellation, stdout: stdout))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    nonisolated private static func agentWorker(
        executable: URL, arguments: [String], cwd: URL, environment: [String: String],
        timeout: TimeInterval, maximumOutputBytes: Int, stderrTailBytes: Int,
        cancellation: AgentProcessCancellation, stdout: @Sendable (Data) throws -> Void
    ) throws -> ProcessResult {
        if cancellation.cancelled { throw CancellationError() }
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw ScriptError.invalid("Cannot open agent stdout pipe.") }
        defer { close(out[0]); if out[1] >= 0 { close(out[1]) } }
        guard pipe(&err) == 0 else { throw ScriptError.invalid("Cannot open agent stderr pipe.") }
        defer { close(err[0]); if err[1] >= 0 { close(err[1]) } }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ScriptError.invalid("Cannot initialize agent file actions.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw ScriptError.invalid("Cannot initialize agent process attributes.") }
        defer { posix_spawnattr_destroy(&attributes) }
        let setup = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO),
            cwd.path.withCString { posix_spawn_file_actions_addchdir(&actions, $0) },
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        ]
        guard setup.allSatisfy({ $0 == 0 }) else { throw ScriptError.invalid("Agent process isolation setup was refused.") }
        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv { free(pointer) }; for pointer in envp { free(pointer) } }
        var pid: pid_t = 0
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
            throw ScriptError.invalid("Cannot allocate agent arguments/environment.")
        }
        let launch = executable.path.withCString { posix_spawn(&pid, $0, &actions, &attributes, &argv, &envp) }
        close(out[1]); out[1] = -1
        close(err[1]); err[1] = -1
        guard launch == 0 else { throw ProcessRunnerError.launchFailed(executable.lastPathComponent, underlying: "spawn error \(launch)") }
        var reaped = false
        var status: Int32 = 0
        defer {
            // Kill the entire group even when the CLI exited successfully: a
            // descendant holding pipes must not survive or prevent cleanup.
            kill(-pid, SIGKILL)
            if !reaped { while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
        }
        guard fcntl(out[0], F_SETFL, O_NONBLOCK) != -1, fcntl(err[0], F_SETFL, O_NONBLOCK) != -1 else {
            throw ScriptError.invalid("Cannot configure nonblocking agent pipes.")
        }
        var descriptors = [pollfd(fd: out[0], events: Int16(POLLIN), revents: 0),
                           pollfd(fd: err[0], events: Int16(POLLIN), revents: 0)]
        let started = ContinuousClock.now
        var total = 0
        var tail = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var eof: Set<Int> = []
        while !reaped || eof.count < 2 {
            if cancellation.cancelled { throw CancellationError() }
            if started.duration(to: .now) >= .seconds(timeout) { throw ProcessRunnerError.timedOut(executable.lastPathComponent) }
            _ = poll(&descriptors, 2, 25)
            for index in 0..<2 where !eof.contains(index) {
                // Read at most one chunk per pipe per iteration; noisy stdout
                // cannot starve stderr, cancellation, waitpid or the deadline.
                let count = read(descriptors[index].fd, &buffer, buffer.count)
                if count == 0 { eof.insert(index); continue }
                if count < 0 {
                    if errno != EAGAIN && errno != EINTR { throw ScriptError.invalid("Agent pipe read failed.") }
                    continue
                }
                total += count
                guard total <= maximumOutputBytes else { throw ScriptError.invalid("Agent stdout/stderr budget exhausted.") }
                let data = Data(buffer.prefix(count))
                if index == 0 { try stdout(data) }
                else { tail.append(data); tail = Data(tail.suffix(max(0, stderrTailBytes))) }
            }
            if !reaped {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid {
                    reaped = true
                    kill(-pid, SIGKILL)
                } else if result < 0 && errno != EINTR { throw ScriptError.invalid("Cannot reap agent process.") }
            }
        }
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return ProcessResult(stdout: Data(), stderr: tail, exitCode: code)
    }
}
