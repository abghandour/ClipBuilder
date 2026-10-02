import Foundation

/// Each request starts in a fresh folder with only its frame files.
nonisolated struct AntigravityRequest: Sendable {
    let frameNames: [String]
    let prompt: String
    let arguments: [String]

    static let frameInstruction = "These files are video frames in order in the current folder. "
        + "Open each one with your file viewing tool and look at it before answering. "
        + "Do not run shell commands or scripts; they are not available."

    init(prompt: String, frameLabels: [String], model: String?, timeout: TimeInterval) {
        frameNames = frameLabels.indices.map { String(format: "frame_%03d.jpg", $0) }
        if frameLabels.isEmpty {
            self.prompt = prompt
        } else {
            let references = zip(frameLabels, frameNames).map { "[Frame at \($0)] \($1)" }
            // Without the last sentence the agent scripts a batch of 30
            // frames, the sandbox refuses the command, and nothing comes back.
            self.prompt = references.joined(separator: "\n")
                + "\n" + Self.frameInstruction + "\n\n"
                + prompt
        }
        // Keep every flag before the attached print value: a separate
        // --print argument can swallow the following flag as its prompt.
        arguments = ["--mode", "plan", "--sandbox",
                     "--model", model ?? "gemini-3.8-flash-medium",
                     "--output-format", "json", "--print-timeout", "\(timeout)s",
                     "--print=\(self.prompt)"]
    }
}
