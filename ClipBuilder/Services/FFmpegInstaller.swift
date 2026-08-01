import Foundation

nonisolated enum FFmpegInstallError: Error, CustomStringConvertible {
    case brewFailed(exitCode: Int32, stderr: String)
    case downloadFailed(tool: String, reason: String)
    case unzipFailed(tool: String, stderr: String)
    case notInstalledAfterInstall

    var description: String {
        switch self {
        case .brewFailed(let code, let stderr):
            let tail = stderr.split(separator: "\n").suffix(4).joined(separator: "\n")
            return "brew install ffmpeg failed (exit \(code)): \(tail)"
        case .downloadFailed(let tool, let reason):
            return "Could not download \(tool): \(reason)"
        case .unzipFailed(let tool, let stderr):
            let tail = stderr.split(separator: "\n").suffix(2).joined(separator: "\n")
            return "Could not unpack \(tool): \(tail)"
        case .notInstalledAfterInstall:
            return "The install finished but ffmpeg still can't be found. Install it manually with: brew install ffmpeg"
        }
    }
}

/// Installs the ffmpeg + ffprobe binaries the pipeline depends on. Prefers
/// `brew install ffmpeg` (lands where the user's package manager can update
/// it); without Homebrew, downloads static builds into the app's managed bin
/// folder, which ProcessRunner.locate searches first.
nonisolated enum FFmpegInstaller {
    static var isInstalled: Bool {
        ProcessRunner.locate("ffmpeg") != nil && ProcessRunner.locate("ffprobe") != nil
    }

    static func install(log: @escaping @Sendable (String) -> Void) async throws {
        if let brew = ProcessRunner.locate("brew") {
            do {
                try await installWithHomebrew(brew, log: log)
                ProcessRunner.resetLocateCache()
                if isInstalled { return }
                // Brew can exit 0 without restoring binaries (formula
                // recorded as installed but the links are gone).
                log("ffmpeg is still missing after Homebrew — downloading static builds instead...")
            } catch {
                log("Homebrew install failed (\(error)) — downloading static builds instead...")
            }
        }
        try await installStaticBuilds(log: log)
        ProcessRunner.resetLocateCache()
        guard isInstalled else { throw FFmpegInstallError.notInstalledAfterInstall }
    }

    // MARK: - Homebrew

    private static func installWithHomebrew(_ brew: URL,
                                            log: @escaping @Sendable (String) -> Void) async throws {
        log("Installing ffmpeg with Homebrew — this can take a few minutes...")
        let result = try await ProcessRunner.run(
            executable: brew, arguments: ["install", "ffmpeg"], timeout: 1800,
            environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "NONINTERACTIVE": "1"])
        guard result.exitCode == 0 else {
            throw FFmpegInstallError.brewFailed(exitCode: result.exitCode, stderr: result.stderrText)
        }
    }

    // MARK: - Static builds (no Homebrew)

    /// Per-architecture single-binary zips from https://ffmpeg.martin-riedl.de.
    private static var staticBuildBase: String {
        #if arch(arm64)
        "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release"
        #else
        "https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release"
        #endif
    }

    private static func installStaticBuilds(log: @escaping @Sendable (String) -> Void) async throws {
        let bin = ProcessRunner.managedBinDirectory
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in ["ffmpeg", "ffprobe"] {
            log("Downloading \(tool)...")
            let zip = try await download(tool: tool)
            defer { try? FileManager.default.removeItem(at: zip) }
            try await unzip(zip, tool: tool, into: bin)
            let binary = bin.appendingPathComponent(tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            // Downloaded executables won't pass Gatekeeper if quarantined.
            removexattr(binary.path, "com.apple.quarantine", 0)
            log("Installed \(tool) into \(bin.path)")
        }
    }

    /// The mirror's `latest` redirect 404s on some of its load-balanced
    /// backends, so retry — with a fresh session each attempt, because a
    /// kept-alive connection would pin every retry to the same bad backend.
    private static func download(tool: String) async throws -> URL {
        let url = URL(string: "\(staticBuildBase)/\(tool).zip")!
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
                let zip = temporary.deletingPathExtension().appendingPathExtension("zip")
                try? FileManager.default.removeItem(at: zip)
                try FileManager.default.moveItem(at: temporary, to: zip)
                return zip
            } catch {
                reason = error.localizedDescription
            }
        }
        throw FFmpegInstallError.downloadFailed(tool: tool, reason: reason)
    }

    private static func unzip(_ zip: URL, tool: String, into folder: URL) async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", zip.path, folder.path], timeout: 120)
        guard result.exitCode == 0 else {
            throw FFmpegInstallError.unzipFailed(tool: tool, stderr: result.stderrText)
        }
    }
}
