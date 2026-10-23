import Foundation

/// Speaks a dub line with a Siri voice. macOS hides Siri voices from
/// third-party processes, so the line goes through the voice's shortcut
/// ("Clip Builder Dub <Name>", one action: Make Spoken Audio from Text),
/// which writes an AAC file; ffmpeg turns it into the CAF the mixer expects
/// and applies the fit rate, which the shortcut cannot take per run.
nonisolated enum SiriDubSynthesizer {
    static let timeout: TimeInterval = 120

    /// ffmpeg arguments that turn the shortcut's AAC into a 48 kHz float CAF
    /// at the requested rate. `atempo` keeps pitch; one stage covers 0.5–2×.
    static func conversionArguments(input: URL, output: URL, rate: Double) -> [String] {
        var arguments = ["-y", "-nostdin", "-i", input.path]
        if rate > 1 + 1e-9 {
            arguments += ["-filter:a", "atempo=\(String(format: "%.4f", rate))"]
        }
        arguments += ["-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", "-f", "caf", output.path]
        return arguments
    }

    static func synthesize(text: String, voice: String, rate: Double, directory: URL) async throws -> URL {
        try Task.checkCancellation()
        guard SiriDubVoices.isSiri(voice) else {
            throw ScriptError.invalid("\(voice) is not a Siri voice.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rate.isFinite, rate >= 1, rate <= 1.25 else {
            throw ScriptError.invalid("A dub line needs text and a speech rate between 1 and 1.25.")
        }
        let language = SiriDubVoices.downloadedVoices().first { $0.identifier == voice }?.language ?? "siri"
        let name = try DubSynthesizer.cacheName(language: language, voice: voice, rate: rate, text: text)
        let output = directory.appendingPathComponent(name)
        if (try? DubSynthesizer.fileDuration(of: output)) ?? 0 > 0 { return output }
        let shortcut = SiriDubVoices.shortcutName(for: voice)
        guard FileManager.default.isExecutableFile(atPath: SiriDubVoices.shortcutsExecutable.path) else {
            throw ScriptError.invalid("The Shortcuts command line tool (/usr/bin/shortcuts) is missing; Siri voices need macOS 12 or later.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let spoken = directory.appendingPathComponent(UUID().uuidString + ".m4a")
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".caf")
        defer {
            try? FileManager.default.removeItem(at: spoken)
            try? FileManager.default.removeItem(at: temporary)
        }
        let result = try await ProcessRunner.run(executable: SiriDubVoices.shortcutsExecutable,
            arguments: ["run", shortcut, "--output-path", spoken.path],
            stdin: Data(text.utf8), timeout: timeout)
        try Task.checkCancellation()
        let size = (try? FileManager.default.attributesOfItem(atPath: spoken.path)[.size] as? Int) ?? 0
        guard result.exitCode == 0, size > 0 else {
            let detail = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let installed = await SiriDubVoices.installedShortcuts()
            if !installed.contains(shortcut) {
                throw ScriptError.invalid("The shortcut “\(shortcut)” is not in the Shortcuts app. "
                    + "Open the dub settings, choose Siri voices and follow Set up.")
            }
            throw ScriptError.invalid("The shortcut “\(shortcut)” produced no audio"
                + (detail.isEmpty ? "." : ": \(detail)") + " Open it in Shortcuts and run it once to allow its output.")
        }
        _ = try await FFmpeg.run(conversionArguments(input: spoken, output: temporary, rate: rate),
                                 timeout: timeout, purpose: "siri dub line")
        guard try DubSynthesizer.fileDuration(of: temporary) > 0 else {
            throw ScriptError.invalid("The Siri voice returned an empty dub line.")
        }
        if (try? DubSynthesizer.fileDuration(of: output)) ?? 0 <= 0 {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: temporary, to: output)
        }
        return output
    }
}
