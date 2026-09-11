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
        #expect(ProviderAuth.loginCommand(provider: "nope") == nil)
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
}
