import Foundation

nonisolated enum ToolInstallError: Error, CustomStringConvertible {
    case brewFailed(exitCode: Int32, stderr: String)
    case downloadFailed(tool: String, reason: String)
    case unzipFailed(tool: String, stderr: String)
    case notInstalledAfterInstall(tools: [String])

    var description: String {
        switch self {
        case .brewFailed(let code, let stderr):
            let tail = stderr.split(separator: "\n").suffix(4).joined(separator: "\n")
            return "brew install failed (exit \(code)): \(tail)"
        case .downloadFailed(let tool, let reason):
            return "Could not download \(tool): \(reason)"
        case .unzipFailed(let tool, let stderr):
            let tail = stderr.split(separator: "\n").suffix(2).joined(separator: "\n")
            return "Could not unpack \(tool): \(tail)"
        case .notInstalledAfterInstall(let tools):
            let list = tools.joined(separator: ", ")
            return "The install finished but \(list) still can't be found. "
                + "Install manually with: brew install \(tools.joined(separator: " "))"
        }
    }
}

/// Installs the command-line tools the pipeline depends on: ffmpeg + ffprobe
/// (probing, frames, rendering) and yt-dlp (Instagram downloads). Prefers
/// Homebrew (lands where the user's package manager can update them); without
/// Homebrew, downloads standalone builds into the app's managed bin folder,
/// which ProcessRunner.locate searches first.
nonisolated enum ToolInstaller {
    /// Every tool the app requires → the Homebrew formula that provides it.
    static let requiredTools: [(name: String, formula: String)] = [
        ("ffmpeg", "ffmpeg"),
        ("ffprobe", "ffmpeg"),   // ships inside the ffmpeg formula
        ("yt-dlp", "yt-dlp"),
    ]

    static var missingTools: [String] {
        requiredTools.map(\.name).filter { ProcessRunner.locate($0) == nil }
    }

    static var allInstalled: Bool { missingTools.isEmpty }

    static func installMissing(log: @escaping @Sendable (String) -> Void) async throws {
        var missing = missingTools
        guard !missing.isEmpty else { return }
        if let brew = ProcessRunner.locate("brew") {
            let formulae = Set(requiredTools.filter { missing.contains($0.name) }.map(\.formula)).sorted()
            do {
                try await installWithHomebrew(brew, formulae: formulae, log: log)
                ProcessRunner.resetLocateCache()
                missing = missingTools
                if missing.isEmpty { return }
                // Brew can exit 0 without restoring binaries (formula
                // recorded as installed but the links are gone).
                log("\(missing.joined(separator: ", ")) still missing after Homebrew — downloading standalone builds instead...")
            } catch {
                log("Homebrew install failed (\(error)) — downloading standalone builds instead...")
            }
        }
        try await installStandaloneBuilds(missing, log: log)
        ProcessRunner.resetLocateCache()
        let stillMissing = missingTools
        guard stillMissing.isEmpty else {
            throw ToolInstallError.notInstalledAfterInstall(tools: stillMissing)
        }
    }

    // MARK: - Homebrew

    private static func installWithHomebrew(_ brew: URL, formulae: [String],
                                            log: @escaping @Sendable (String) -> Void) async throws {
        log("Installing \(formulae.joined(separator: ", ")) with Homebrew — this can take a few minutes...")
        let result = try await ProcessRunner.run(
            executable: brew, arguments: ["install"] + formulae, timeout: 1800,
            environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "NONINTERACTIVE": "1"])
        guard result.exitCode == 0 else {
            throw ToolInstallError.brewFailed(exitCode: result.exitCode, stderr: result.stderrText)
        }
    }

    // MARK: - Standalone builds (no Homebrew)

    /// Per-architecture single-binary ffmpeg/ffprobe zips.
    private static var ffmpegBuildBase: String {
        #if arch(arm64)
        "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release"
        #else
        "https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release"
        #endif
    }

    /// yt-dlp's official self-contained macOS build (universal binary).
    private static let ytDlpURL =
        URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    private static func installStandaloneBuilds(_ tools: [String],
                                                log: @escaping @Sendable (String) -> Void) async throws {
        let bin = ProcessRunner.managedBinDirectory
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in tools {
            log("Downloading \(tool)...")
            let binary = bin.appendingPathComponent(tool)
            if tool == "yt-dlp" {
                let downloaded = try await download(tool: tool, from: ytDlpURL)
                try? FileManager.default.removeItem(at: binary)
                try FileManager.default.moveItem(at: downloaded, to: binary)
            } else {
                let zip = try await download(tool: tool,
                                             from: URL(string: "\(ffmpegBuildBase)/\(tool).zip")!)
                defer { try? FileManager.default.removeItem(at: zip) }
                try await unzip(zip, tool: tool, into: bin)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            // Downloaded executables won't pass Gatekeeper if quarantined.
            removexattr(binary.path, "com.apple.quarantine", 0)
            log("Installed \(tool) into \(bin.path)")
        }
    }

    /// Some hosts 404 on a subset of their load-balanced backends, so retry —
    /// with a fresh session each attempt, because a kept-alive connection
    /// would pin every retry to the same bad backend.
    private static func download(tool: String, from url: URL) async throws -> URL {
        var reason = ""
        for attempt in 1...3 {
            if attempt > 1 { try await Task.sleep(for: .seconds(2)) }
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (temporary, response) = try await session.download(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard status == 200 else {
                    reason = "HTTP \(status)"
                    try? FileManager.default.removeItem(at: temporary)
                    continue
                }
                let stable = temporary.deletingLastPathComponent()
                    .appendingPathComponent("clipbuilder-\(tool).download")
                try? FileManager.default.removeItem(at: stable)
                try FileManager.default.moveItem(at: temporary, to: stable)
                return stable
            } catch {
                reason = error.localizedDescription
            }
        }
        throw ToolInstallError.downloadFailed(tool: tool, reason: reason)
    }

    private static func unzip(_ zip: URL, tool: String, into folder: URL) async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", zip.path, folder.path], timeout: 120)
        guard result.exitCode == 0 else {
            throw ToolInstallError.unzipFailed(tool: tool, stderr: result.stderrText)
        }
    }
}
