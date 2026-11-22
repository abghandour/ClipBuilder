import Foundation
import Testing
@testable import Clip_Builder

@Suite("Provider sign-in")
struct ProviderAuthTests {
    @Test("auth failures are recognized by the phrases the CLIs print")
    func authFailurePhrases() {
        #expect(ProviderAuth.isAuthFailure("Failed to authenticate: OAuth session expired and could not be refreshed"))
        for phrase in ["failed to authenticate", "session expired", "error authenticating", "could not be refreshed"] {
            #expect(ProviderAuth.isAuthFailure(phrase))
        }
        #expect(ProviderAuth.isAuthFailure("Not logged in · Please run /login"))
        #expect(ProviderAuth.isAuthFailure("OAuth token has expired. Please obtain a new token."))
        #expect(ProviderAuth.isAuthFailure("Error: Invalid API key · Fix external API key"))
        #expect(ProviderAuth.isAuthFailure("{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\"}}"))
        #expect(ProviderAuth.isAuthFailure("401 Unauthorized"))
        #expect(ProviderAuth.isAuthFailure("Not authenticated. Run 'codex login'."))
    }

    @Test("ordinary errors are not mistaken for sign-in problems")
    func nonAuthPhrases() {
        // "author" and "OAuth" inside unrelated text used to trip the old
        // substring check.
        #expect(!ProviderAuth.isAuthFailure("The author of this clip is unknown"))
        #expect(!ProviderAuth.isAuthFailure("Prompt is too long: 250000 tokens > 200000 maximum"))
        #expect(!ProviderAuth.isAuthFailure("env: node: No such file or directory"))
        #expect(!ProviderAuth.isAuthFailure("Rate limit exceeded, retry later"))
        #expect(!ProviderAuth.isAuthFailure("Model returned an empty response"))
        #expect(!ProviderAuth.isAuthFailure(""))
    }

    @Test("claude auth status JSON decides sign-in, prose falls back")
    func claudeStatus() {
        #expect(ProviderAuth.parseClaudeStatus(
            stdout: "{\"loggedIn\": true, \"authMethod\": \"claude.ai\"}", stderr: "", exitCode: 0) == .signedIn)
        #expect(ProviderAuth.parseClaudeStatus(
            stdout: "{\"loggedIn\": false}", stderr: "", exitCode: 0) == .signedOut)
        #expect(ProviderAuth.parseClaudeStatus(
            stdout: "Not logged in", stderr: "", exitCode: 1) == .signedOut)
        #expect(ProviderAuth.parseClaudeStatus(
            stdout: "Logged in as someone@example.com", stderr: "", exitCode: 0) == .signedIn)
        #expect(ProviderAuth.parseClaudeStatus(stdout: "", stderr: "", exitCode: 0) == .unknown)
        #expect(ProviderAuth.parseClaudeStatus(stdout: "", stderr: "boom", exitCode: 1) == .signedOut)
    }

    @Test("codex login status prose decides sign-in")
    func codexStatus() {
        #expect(ProviderAuth.parseCodexStatus(stdout: "Logged in using ChatGPT", stderr: "", exitCode: 0) == .signedIn)
        #expect(ProviderAuth.parseCodexStatus(stdout: "Not logged in", stderr: "", exitCode: 1) == .signedOut)
        #expect(ProviderAuth.parseCodexStatus(stdout: "", stderr: "", exitCode: 0) == .unknown)
    }

    @Test("every catalog provider has a login command")
    func loginCommands() {
        for provider in AICatalog.providers {
            #expect(ProviderAuth.loginCommand(provider: provider.key) != nil, Comment(rawValue: provider.key))
        }
        #expect(ProviderAuth.loginCommand(provider: "claude") == "claude auth login")
        #expect(ProviderAuth.loginCommand(provider: "codex") == "codex login")
        #expect(ProviderAuth.loginCommand(provider: "antigravity") == "agy")
        #expect(ProviderAuth.loginCommand(provider: "nope") == nil)
    }

    @Test("Antigravity has no status command and never reports signed out by guessing")
    func antigravityStatus() async {
        #expect(await ProviderAuth.status(provider: "antigravity", binary: URL(fileURLWithPath: "/bin/false")) == .unknown)
        #expect(await ProviderAuth.status(provider: "antigravity", binary: nil) == .unknown)
    }

    @Test("the sign-in script runs the located binary in a login shell and waits")
    func signInScript() throws {
        let script = try #require(ProviderAuth.signInScript(
            provider: "claude", label: "Claude Code",
            binary: URL(fileURLWithPath: "/Users/someone/.nvm/versions/node/v22/bin/claude")))
        #expect(script.hasPrefix("#!/bin/zsh -l\n"))
        #expect(script.contains("'/Users/someone/.nvm/versions/node/v22/bin/claude' auth login"))
        #expect(script.contains("Signing in to Claude Code"))
        #expect(script.contains("read -k1"))

        let unlocated = try #require(ProviderAuth.signInScript(provider: "gemini", label: "Gemini CLI", binary: nil))
        #expect(unlocated.contains("\ngemini\n"))
        #expect(ProviderAuth.signInScript(provider: "nope", label: "Nope", binary: nil) == nil)
    }

    @Test("a not-authenticated AI error becomes an alert with a Sign In provider")
    func alertCarriesProvider() {
        let error = AIError.notAuthenticated(provider: "claude", detail: "Not logged in · Please run /login")
        let alert = AppError.failure(context: "People detection failed", error: error)
        #expect(alert.signInProvider == "claude")
        #expect(alert.message.hasPrefix("People detection failed: Claude Code is not signed in."))
        #expect(alert.message.contains("Not logged in · Please run /login"))
        // Details never repeat the message when reflection adds nothing.
        #expect(alert.details == error.description)

        let plain = AppError.failure(context: "Render failed", error: AIError.emptyResponse("Claude"))
        #expect(plain.signInProvider == nil)
        #expect(plain.message == "Render failed: Claude returned an empty response")
    }

    @Test("the login shell PATH goes first and nothing the app had is lost")
    func mergedPATH() {
        let merged = ProcessRunner.mergedPATH(login: "/Users/x/.nvm/bin:/opt/homebrew/bin:/usr/bin",
                                              current: "/usr/bin:/bin:/usr/sbin")
        #expect(merged == "/Users/x/.nvm/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin")
        #expect(ProcessRunner.mergedPATH(login: "/a::/b", current: nil) == "/a:/b")
        let environment = ProcessRunner.subprocessEnvironment(overrides: ["FOO": "bar"])
        #expect(environment["FOO"] == "bar")
        #expect(environment["PATH"]?.isEmpty == false)
    }

    @Test func signInScriptAvoidsZshReadOnlyStatus() throws {
        let script = try #require(ProviderAuth.signInScript(provider: "claude", label: "Claude", binary: nil))
        #expect(!script.contains("status="))
        #expect(script.contains("exit $result"))
    }

    @Test("Antigravity's model list says whether it is signed in")
    func antigravityModelsStatus() {
        #expect(ProviderAuth.parseAntigravityModels(stdout: "", stderr: """
            Fetching available models...
            Error: Please sign in to view available models. Launch the CLI without arguments to sign in.
            """, exitCode: 1) == .signedOut)
        #expect(ProviderAuth.parseAntigravityModels(stdout: "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n",
                                                    stderr: "Fetching available models...\n", exitCode: 0) == .signedIn)
        #expect(ProviderAuth.parseAntigravityModels(stdout: "", stderr: "dial tcp: i/o timeout", exitCode: 1) == .unknown)
        // What a prompt prints when signed out is a sign-in failure for the caller.
        #expect(ProviderAuth.isAuthFailure("Error: authentication required. Run 'agy' to log in, then retry."))
    }

    @Test("The Antigravity sign-in reads the page address and the CLI's verdict")
    func antigravitySignInParsing() {
        let prompt = """
            Authentication required. Please visit the URL to log in:
              https://accounts.google.com/o/oauth2/auth?access_type=offline&response_type=code

            Waiting for authentication (timeout 60s)...
            Or, paste the authorization code here and press Enter:

            """
        #expect(AntigravitySignIn.page(in: prompt)?.host == "accounts.google.com")
        // Not while the address is still arriving.
        #expect(AntigravitySignIn.page(in: "Authentication required.\n  https://accounts.google.com/o/oau") == nil)
        #expect(AntigravitySignIn.outcome(exitCode: 1, stderr: prompt + "Error: authentication timed out.\n") == .timedOut)
        let refused = AntigravitySignIn.outcome(exitCode: 1, stderr: prompt
            + "Error: authentication failed: token exchange failed: oauth2: \"invalid_grant\" \"Bad Request\"\n")
        if case .failed(let message) = refused { #expect(message.contains("did not accept")) } else { Issue.record("\(refused)") }
        #expect(AntigravitySignIn.outcome(exitCode: 0, stderr: prompt) == .signedIn)
        #expect(AntigravitySignIn.outcome(exitCode: 1, stderr: "Error: authentication required. Run 'agy' to log in, then retry.\n")
            == .failed("authentication required. Run 'agy' to log in, then retry."))
        // Stopped, or failed for a reason that is not the sign-in: only the CLI's status can tell.
        #expect(AntigravitySignIn.outcome(exitCode: 15, stderr: prompt) == .unclear("The Antigravity CLI stopped (status 15)."))
        #expect(AntigravitySignIn.outcome(exitCode: 1, stderr: prompt + "error: model not found\n") == .unclear("error: model not found"))
        // Only the first pasted line is typed, and never an endless one.
        #expect(AntigravitySignIn.codeLine("\n  4/abc  \nsecond line\n") == "4/abc")
        #expect(AntigravitySignIn.codeLine(String(repeating: "x", count: 5000)).count == 512)
        // A list is the only evidence of being signed in.
        #expect(ProviderAuth.parseAntigravityModels(stdout: "models\n", stderr: "", exitCode: 0) == .unknown)
    }

    @Test("A pasted code reaches the CLI on its terminal", .timeLimit(.minutes(1)))
    func antigravitySignInTypesTheCode() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agy-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("agy")
        // Like the CLI: interactive only when stdin is a terminal.
        try """
            #!/bin/sh
            if [ ! -t 0 ]; then echo "Error: authentication required. Run 'agy' to log in, then retry." >&2; exit 1; fi
            echo "Authentication required. Please visit the URL to log in:" >&2
            echo "  https://accounts.google.com/o/oauth2/auth?state=fake" >&2
            echo "Or, paste the authorization code here and press Enter:" >&2
            read code
            if [ "$code" = "4/good" ]; then exit 0; fi
            echo 'Error: authentication failed: token exchange failed: oauth2: "invalid_grant" "Bad Request"' >&2
            exit 1

            """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        for (code, accepted) in [("  4/good \n", true), ("4/bad", false)] {
            let session = try AntigravitySignIn(binary: binary)
            var events: [AntigravitySignIn.Event] = []
            for await event in session.events {
                events.append(event)
                if case .page = event { session.submit(code: code) }
            }
            #expect(events.first == .page(URL(string: "https://accounts.google.com/o/oauth2/auth?state=fake")!))
            if accepted {
                #expect(events.last == .finished(.signedIn))
            } else if case .finished(.failed)? = events.last {} else {
                Issue.record("\(events)")
            }
        }
    }
}
