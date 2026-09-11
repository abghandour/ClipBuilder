import AppKit
import Foundation

/// Sign-in state of the AI provider CLIs, and the way back in.
///
/// Every provider signs in through its own CLI (a browser OAuth flow the
/// CLI starts and waits on), so the app can neither hold the credentials
/// nor open the consent page itself. What it can do is ask the CLI whether
/// it is signed in, tell an auth failure apart from any other error, and
/// launch the CLI's login command in a visible Terminal window.
nonisolated enum ProviderAuth {
    enum State: Sendable, Equatable {
        case signedIn
        case signedOut
        /// The CLI has no status command and no credential file we know.
        case unknown
    }

    // MARK: - Classifying failures

    /// Phrases the CLIs actually print when credentials are missing or
    /// stale. Kept narrow on purpose: a bare "auth" once matched "OAuth"
    /// inside unrelated messages and "author" in model replies.
    private static let authFailureMarkers = [
        "not logged in", "not authenticated", "not signed in",
        "please run /login", "run /login", "please log in", "please login", "please sign in",
        "invalid api key", "invalid_api_key", "api key not found", "missing api key",
        "authentication_error", "authentication failed", "authentication required",
        "unauthorized",
        "oauth token", "token has expired", "token expired", "invalid_grant",
        "credentials not found", "no credentials", "login required",
    ]

    /// True when a CLI's error text says its sign-in is missing or stale.
    static func isAuthFailure(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return authFailureMarkers.contains { lowered.contains($0) }
    }

    // MARK: - Status

    /// Ask the CLI itself. Claude and Codex have status commands; Gemini
    /// and Qwen keep an OAuth credential file we can look for; Kimi offers
    /// neither. Never throws — an unreadable answer is `.unknown`.
    static func status(provider key: String, binary: URL?) async -> State {
        switch key {
        case "claude":
            guard let binary else { return .unknown }
            guard let result = try? await ProcessRunner.run(
                executable: binary, arguments: ["auth", "status"], timeout: 20) else { return .unknown }
            return parseClaudeStatus(stdout: result.stdoutText, stderr: result.stderrText,
                                     exitCode: result.exitCode)
        case "codex":
            guard let binary else { return .unknown }
            guard let result = try? await ProcessRunner.run(
                executable: binary, arguments: ["login", "status"], timeout: 20) else { return .unknown }
            return parseCodexStatus(stdout: result.stdoutText, stderr: result.stderrText,
                                    exitCode: result.exitCode)
        case "gemini":
            if ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?.isEmpty == false { return .signedIn }
            return credentialFileState(".gemini/oauth_creds.json")
        case "qwen":
            return credentialFileState(".qwen/oauth_creds.json")
        default:
            return .unknown
        }
    }

    /// `claude auth status` prints JSON with a `loggedIn` flag (older
    /// builds print prose, which falls back to the phrase check).
    static func parseClaudeStatus(stdout: String, stderr: String, exitCode: Int32) -> State {
        if let data = stdout.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let loggedIn = object["loggedIn"] as? Bool {
            return loggedIn ? .signedIn : .signedOut
        }
        let text = (stdout + "\n" + stderr).lowercased()
        if text.contains("not logged in") || text.contains("logged out") { return .signedOut }
        if text.contains("logged in") { return .signedIn }
        return exitCode == 0 ? .unknown : .signedOut
    }

    /// `codex login status` prints "Logged in using …" or "Not logged in".
    static func parseCodexStatus(stdout: String, stderr: String, exitCode: Int32) -> State {
        let text = (stdout + "\n" + stderr).lowercased()
        if text.contains("not logged in") { return .signedOut }
        if text.contains("logged in") { return .signedIn }
        return exitCode == 0 ? .unknown : .signedOut
    }

    private static func credentialFileState(_ relativePath: String) -> State {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: path) ? .signedIn : .signedOut
    }

    // MARK: - Signing in

    /// The command that starts each CLI's sign-in flow.
    static func loginCommand(provider key: String) -> String? {
        switch key {
        case "claude": "claude auth login"
        case "codex": "codex login"
        // These prompt for sign-in on first launch.
        case "gemini": "gemini"
        case "qwen": "qwen"
        case "kimi": "kimi"
        default: nil
        }
    }

    /// The Terminal script that runs the sign-in. A login shell so the
    /// CLI resolves the way it does in the user's own Terminal (nvm, npm,
    /// Homebrew paths), then waits so the result stays readable.
    static func signInScript(provider key: String, label: String, binary: URL?) -> String? {
        guard let command = loginCommand(provider: key) else { return nil }
        // Prefer the exact binary the app found so the same install signs in.
        let resolved: String
        if let binary {
            let rest = command.split(separator: " ").dropFirst().joined(separator: " ")
            resolved = shellQuoted(binary.path) + (rest.isEmpty ? "" : " " + rest)
        } else {
            resolved = command
        }
        return """
        #!/bin/zsh -l
        clear
        echo "Signing in to \(label) for Clip Builder…"
        echo "Follow the prompts below (a browser window may open)."
        echo
        \(resolved)
        status=$?
        echo
        if [ $status -eq 0 ]; then
            echo "Done. You can close this window and go back to Clip Builder."
        else
            echo "The sign-in command exited with status $status. Check the messages above, then try again."
        fi
        echo
        read -k1 "?Press any key to close this window."
        exit $status

        """
    }

    /// Write the script and hand it to Terminal. Terminal opens the
    /// `.command` file in a new window; the app only waits for the user to
    /// come back.
    @MainActor
    static func openSignInTerminal(provider key: String, binary: URL?) throws {
        let label = AICatalog.provider(key)?.label ?? key
        guard let script = signInScript(provider: key, label: label, binary: binary) else {
            throw AIError.notConfigured("\(label) has no sign-in command Clip Builder knows how to run.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipbuilder-signin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Sign in to \(label).command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        if FileManager.default.fileExists(atPath: terminal.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: configuration) { _, error in
                // Fall back to whatever handles .command files.
                if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(file) } }
            }
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
