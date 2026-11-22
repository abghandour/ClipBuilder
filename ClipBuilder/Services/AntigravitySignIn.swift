import Darwin
import Foundation

/// One run of the Antigravity CLI's own sign-in, driven from the app.
///
/// The CLI has no login command. Signed out, a prompt makes it open the
/// Google sign-in page in the browser and wait a minute for either the
/// browser's callback or the authorization code typed on its terminal;
/// with a pipe or a file for stdin it gives up at once. So the prompt runs
/// on a pseudo-terminal, and the code the page shows is written to it.
nonisolated final class AntigravitySignIn: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        /// The Google sign-in page the CLI opened in the browser.
        case page(URL)
        /// The CLI exited: signed in, or why not.
        case finished(Outcome)
    }

    enum Outcome: Sendable, Equatable {
        /// The CLI accepted the sign-in and answered its prompt.
        case signedIn
        case timedOut
        case failed(String)
        /// The CLI failed without saying the sign-in did: only its own
        /// status can tell whether it is signed in now.
        case unclear(String)
    }

    /// The CLI waits this long for the code.
    static let wait: TimeInterval = 60

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let process = Process()
    private let terminal: FileHandle
    private let lock = NSLock()
    private var errorText = ""
    private var pageSent = false

    /// Starts the CLI; it opens the browser itself.
    init(binary: URL) throws {
        (events, continuation) = AsyncStream<Event>.makeStream()
        // O_NOCTTY on both ends: a GUI app has no controlling terminal, and
        // `openpty` would make this one the app's own, so that the CLI
        // exiting hangs up (SIGHUP) the app.
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            if master >= 0 { close(master) }
            throw AIError.notConfigured("Could not open a terminal for the Antigravity sign-in.")
        }
        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            throw AIError.notConfigured("Could not open a terminal for the Antigravity sign-in.")
        }
        terminal = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let input = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb_antigravity_signin_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = binary
        process.arguments = ["--mode", "plan", "--sandbox", "--output-format", "json",
                             "--print-timeout", "60s", "--print=Reply with the single word ok."]
        process.environment = ProcessRunner.subprocessEnvironment(overrides: nil)
        process.currentDirectoryURL = directory
        process.standardInput = input
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // The verdict waits for the reader of stderr, so it is never formed
        // before the CLI's last words. The readers stop soon after the CLI
        // exits even when a helper it started keeps the pipes open.
        let exited = Flag()
        let read = DispatchGroup()
        read.enter()
        process.terminationHandler = { [weak self] process in
            exited.set()
            _ = read.wait(timeout: .now() + 2)
            try? FileManager.default.removeItem(at: directory)
            guard let self else { return }
            let text = self.lock.withLock { self.errorText }
            self.continuation.yield(.finished(Self.outcome(exitCode: process.terminationStatus, stderr: text)))
            self.continuation.finish()
        }
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        // Started only for a CLI that runs: a failed launch leaves nothing reading.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Self.drain(errors.fileHandleForReading, until: exited) { self?.received(String(decoding: $0, as: UTF8.self)) }
            read.leave()
        }
        // Drained so the CLI never blocks on a full pipe; the answer is not needed.
        DispatchQueue.global(qos: .utility).async {
            Self.drain(output.fileHandleForReading, until: exited) { _ in }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isSet: Bool { lock.withLock { raised } }
        func set() { lock.withLock { raised = true } }
    }

    /// Reads a pipe until it ends, or until nothing more is waiting in it
    /// once `exited` is set. Never blocks for longer than the poll.
    private static func drain(_ handle: FileHandle, until exited: Flag, _ consume: (Data) -> Void) {
        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, 200)
            if ready > 0 {
                let count = read(descriptor, &buffer, buffer.count)
                guard count > 0 else { return }
                consume(Data(buffer[0..<count]))
            } else if ready == 0 {
                if exited.isSet { return }
            } else if errno != EINTR {
                return
            }
        }
    }

    /// Types the authorization code the sign-in page showed. Off the
    /// caller's thread: a terminal nobody reads can block a write.
    func submit(code: String) {
        let line = Self.codeLine(code) + "\n"
        let terminal = terminal
        DispatchQueue.global(qos: .userInitiated).async {
            try? terminal.write(contentsOf: Data(line.utf8))
        }
    }

    /// The one line to type: the first line of what was pasted, without
    /// spaces, and no longer than any code is.
    static func codeLine(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return String(first.prefix(512))
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }

    private func received(_ text: String) {
        let page: URL? = lock.withLock {
            errorText += text
            guard !pageSent, let url = Self.page(in: errorText) else { return nil }
            pageSent = true
            return url
        }
        if let page { continuation.yield(.page(page)) }
    }

    /// The sign-in address in what the CLI printed, once its line is complete.
    static func page(in text: String) -> URL? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).dropLast() {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            if candidate.hasPrefix("https://"), let url = URL(string: candidate) { return url }
        }
        return nil
    }

    /// What the CLI's exit says. Signed out it ends with "Error:
    /// authentication …"; once the code is accepted it goes on to answer
    /// the prompt, and a failure there says nothing about the sign-in.
    static func outcome(exitCode: Int32, stderr: String) -> Outcome {
        let lowered = stderr.lowercased()
        if lowered.contains("authentication timed out") { return .timedOut }
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let failure = lines.first(where: { $0.lowercased().hasPrefix("error: authentication") }) {
            if failure.lowercased().contains("invalid_grant") {
                return .failed("Google did not accept that code. Codes work once and expire quickly: start again and paste the new one.")
            }
            return .failed(String(failure.dropFirst("Error: ".count)))
        }
        if exitCode == 0 { return .signedIn }
        let said = lines.last { $0.lowercased().hasPrefix("error") } ?? "The Antigravity CLI stopped (status \(exitCode))."
        return .unclear(String(said.prefix(200)))
    }
}
