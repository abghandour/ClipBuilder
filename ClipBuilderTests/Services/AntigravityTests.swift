import Foundation
import Testing
@testable import Clip_Builder

@Suite("Antigravity responses")
struct AntigravityResponseTests {
    @Test("JSON success returns only the response, preserving its inner JSON")
    func success() throws {
        let text = try AntigravityResponse.parse(
            stdout: #"{"conversation_id":"fixture","status":"SUCCESS","response":" {\"ok\":true}\n","num_turns":1}"#,
            stderr: "progress", exitCode: 0)
        #expect(text == #"{"ok":true}"#)
    }

    @Test("ERROR returns the CLI's error even with exit code zero", arguments: [Int32(0), Int32(1)])
    func error(exitCode: Int32) {
        #expect(throws: AntigravityResponse.Failure.cliError("Quota exceeded")) {
            try AntigravityResponse.parse(stdout: #"{"status":"ERROR","error":"Quota exceeded","response":"ignored"}"#,
                                           stderr: "", exitCode: exitCode)
        }
    }

    @Test("A refused tool explains the empty reply", arguments: [Int32(0), Int32(1)])
    func deniedTool(exitCode: Int32) {
        #expect(throws: AntigravityResponse.Failure.deniedTool) {
            try AntigravityResponse.parse(
                stdout: #"{"status":"SUCCESS","response":"","denied_actions":[{"action":"command","display_name":"RunCommand"}]}"#,
                stderr: "no output produced - a tool required the command permission", exitCode: exitCode)
        }
        #expect(AntigravityResponse.Failure.deniedTool.description.contains("tried to use a tool and was refused"))
    }

    @Test("Blank or absent responses without denied tools are empty-response errors", arguments: [
        #"{"status":"SUCCESS","response":" \n","denied_actions":[]}"#,
        #"{"status":"SUCCESS"}"#,
    ])
    func empty(stdout: String) {
        #expect(throws: AntigravityResponse.Failure.emptyResponse) {
            try AntigravityResponse.parse(stdout: stdout, stderr: "", exitCode: 0)
        }
    }

    @Test("Non-JSON uses the first CLI error line, skipping stack frames")
    func nonJSON() {
        #expect(throws: AntigravityResponse.Failure.cliError("Login required")) {
            try AntigravityResponse.parse(stdout: "not JSON", stderr: "\n at ignored.js:1\nLogin required\n at other.js:2", exitCode: 1)
        }
        #expect(throws: AntigravityResponse.Failure.cliError("CLI failed")) {
            try AntigravityResponse.parse(stdout: "CLI failed\nmore", stderr: "", exitCode: 0)
        }
    }

    @Test("A nonzero exit cannot return a partial success")
    func failedExit() {
        #expect(throws: AntigravityResponse.Failure.cliError("Process failed")) {
            try AntigravityResponse.parse(stdout: #"{"status":"SUCCESS","response":"partial"}"#,
                                           stderr: "Process failed", exitCode: 2)
        }
    }
}

@Suite("Antigravity requests")
struct AntigravityRequestTests {
    @Test("Text prompts use an attached final print argument, including leading dashes and newlines")
    func text() {
        let prompt = "---\nUntrusted transcript\n--dangerously-skip-permissions"
        let request = AntigravityRequest(prompt: prompt, frameLabels: [], model: nil, timeout: 120)
        #expect(request.prompt == prompt)
        #expect(request.frameNames.isEmpty)
        #expect(request.arguments == ["--mode", "plan", "--sandbox", "--model", "gemini-3.8-flash-medium",
                                      "--output-format", "json", "--print-timeout", "120.0s", "--print=\(prompt)"])
        #expect(!request.arguments.contains("--dangerously-skip-permissions"))
    }

    @Test("All frames are named in order in the current folder, with timestamps and a viewing instruction")
    func frames() {
        let request = AntigravityRequest(prompt: "Who appears?", frameLabels: ["3.5s", "7.0s"],
                                         model: "gemini-3.1-pro-high", timeout: 45.5)
        #expect(request.frameNames == ["frame_000.jpg", "frame_001.jpg"])
        #expect(request.prompt == """
        [Frame at 3.5s] frame_000.jpg
        [Frame at 7.0s] frame_001.jpg
        These files are video frames in order in the current folder. Open each one with your file viewing tool and look at it before answering. Do not run shell commands or scripts; they are not available.

        Who appears?
        """)
        #expect(request.arguments == ["--mode", "plan", "--sandbox", "--model", "gemini-3.1-pro-high",
                                      "--output-format", "json", "--print-timeout", "45.5s", "--print=\(request.prompt)"])
        #expect(!request.prompt.contains("@"))
    }
}

@Suite("Antigravity dispatch")
struct AntigravityServiceTests {
    @Test("Every request gets its own workspace, containing only its frames, then removes it", arguments: [0, 2])
    func workspace(frameCount: Int) async throws {
        var config = AIConfig()
        config.providers["antigravity"] = AIProviderSettings(bin: "/bin/echo", model: "gemini-3.8-flash-low")
        let capture = AntigravityWorkspaceCapture()
        let frames = (0..<frameCount).map { AIFrame(jpeg: Data([UInt8($0)]), label: "\($0)s") }
        let service = AIService(config: config) { _, arguments, stdin, timeout, environment, currentDirectory in
            let directory = try #require(currentDirectory)
            await capture.append(directory)
            #expect(directory.path != "/")
            #expect(stdin == nil && environment == nil && timeout == 10)
            let request = AntigravityRequest(prompt: "fixture", frameLabels: frames.map(\.label),
                                             model: "gemini-3.8-flash-low", timeout: 10)
            #expect(arguments == request.arguments)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == request.frameNames)
            for (frame, name) in zip(frames, request.frameNames) {
                #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == frame.jpeg)
            }
            return ProcessResult(stdout: Data(#"{"status":"SUCCESS","response":"ok\n"}"#.utf8), stderr: Data(), exitCode: 0)
        }
        for _ in 0..<2 {
            let response = try await service.call(prompt: "fixture", taskKey: "fixture", frames: frames,
                                                  provider: "antigravity", timeout: 10)
            #expect(response.text == "ok" && response.provider == "antigravity")
        }
        let directories = await capture.directories
        #expect(Set(directories).count == 2)
        #expect(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("Timeout and cancellation also remove the workspace", arguments: [false, true])
    func failedProcess(cancelled: Bool) async throws {
        var config = AIConfig()
        config.providers["antigravity"] = AIProviderSettings(bin: "/bin/echo", model: nil)
        let capture = AntigravityWorkspaceCapture()
        let service = AIService(config: config) { _, _, _, _, _, directory in
            await capture.append(try #require(directory))
            if cancelled { throw CancellationError() }
            throw ProcessRunnerError.timedOut("agy")
        }
        do {
            _ = try await service.call(prompt: "fixture", taskKey: "fixture", provider: "antigravity", timeout: 1)
            Issue.record("Expected process failure")
        } catch {
            #expect(cancelled ? error is CancellationError : error is ProcessRunnerError)
        }
        let directories = await capture.directories
        #expect(directories.count == 1)
        #expect(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("JSON failures use the shared quota, prompt and sign-in classifiers", arguments: [
        "Quota exceeded", "Prompt too long", "Not logged in", "Tool refused",
    ])
    func classifiedErrors(message: String) async throws {
        var config = AIConfig()
        config.providers["antigravity"] = AIProviderSettings(bin: "/bin/echo", model: nil)
        let capture = AntigravityWorkspaceCapture()
        let service = AIService(config: config) { _, _, _, _, _, directory in
            await capture.append(try #require(directory))
            let stdout = message == "Tool refused"
                ? #"{"status":"SUCCESS","response":"","denied_actions":[{"action":"command"}]}"#
                : "{\"status\":\"ERROR\",\"error\":\"\(message)\"}"
            return ProcessResult(stdout: Data(stdout.utf8), stderr: Data(), exitCode: 0)
        }
        do {
            _ = try await service.call(prompt: "fixture", taskKey: "fixture", provider: "antigravity", timeout: 10)
            Issue.record("Expected classified failure")
        } catch let error as AIError {
            switch (message, error) {
            case ("Quota exceeded", .quotaExhausted): break
            case ("Prompt too long", .promptTooLong): break
            case ("Not logged in", .notAuthenticated(let provider, _)): #expect(provider == "antigravity")
            case ("Tool refused", .notConfigured(let detail)): #expect(detail.contains("tried to use a tool and was refused"))
            default: Issue.record("Unexpected classification: \(error)")
            }
            #expect(AIService.deservesCooldown(error) == (message != "Prompt too long"))
        }
        let directories = await capture.directories
        #expect(directories.count == 1)
        #expect(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}

private actor AntigravityWorkspaceCapture {
    private(set) var directories: [URL] = []
    func append(_ directory: URL) { directories.append(directory) }
}
