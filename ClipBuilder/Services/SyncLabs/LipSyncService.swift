import Foundation

/// One lip-sync pass over a finished reel: upload the reel and its audio to
/// Sync Labs, wait, download, and put the synced picture under the reel's
/// own audio. docs/Lip-Sync-Plan.md has the steps and their limits.
nonisolated struct LipSyncService: Sendable {
    enum Result: Equatable, Sendable {
        case synced
        /// Sync Labs changed nothing; the reel is as it was.
        case unchanged(String)
    }

    var key: @Sendable () throws -> String? = { try SyncLabsKeychain().read() }
    var client: @Sendable (String) -> SyncLabsClient = { SyncLabsClient(apiKey: $0) }
    var duration: @Sendable (URL) async -> Double = { await FFmpeg.duration(of: $0) }
    /// How long the picture itself runs: the first video stream, not the
    /// container, which a longer audio track would stretch.
    var pictureDuration: @Sendable (URL) async -> Double = { url in
        let text = try? await FFmpeg.probe(["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=duration",
                                            "-of", "default=noprint_wrappers=1:nokey=1", url.path])
        if let seconds = text.flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), seconds > 0 { return seconds }
        return await FFmpeg.duration(of: url)
    }
    var ffmpeg: @Sendable ([String]) async throws -> Void = { try await FFmpeg.run($0, purpose: "lip sync") }
    /// Seconds between two looks at the generation, and the longest wait.
    var pollSeconds = 5.0
    var timeoutSeconds = 3600.0

    /// The model Settings names. Read from disk: the pass runs off the main actor.
    static func chosenModel() -> LipSync.Model { LipSync.model(SettingsStore.loadSettings().ai.lipSync?.model) }

    /// Posted when the key is saved or removed in Settings.
    static let keyChanged = Notification.Name("LipSyncService.keyChanged")

    static var hasKey: Bool { keyState == true }

    /// Whether a key is saved; nil when the keychain could not be read, which
    /// is not the same as having none.
    static var keyState: Bool? {
        do { return try SyncLabsKeychain().read()?.isEmpty == false } catch { return nil }
    }

    /// Replaces `reel` with its lip-synced version. Throws without touching it when anything fails.
    @concurrent
    func sync(reel: URL, model: LipSync.Model, scratch: URL,
              log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Result {
        guard let key = try key()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw SyncLabsError.missingKey
        }
        let client = client(key)
        let seconds = await duration(reel)
        guard seconds > 0 else { throw SyncLabsError.failed("The reel could not be read for lip sync.") }
        let account = try await client.account()
        if let limit = account.limits?.maxOutputDurationSeconds, limit > 0, seconds > limit + 0.5 {
            throw SyncLabsError.tooLong(seconds: seconds, limit: limit)
        }
        log("Lip sync with \(model.label): \(LipSync.length(seconds)), \(LipSync.estimateLabel(seconds: seconds, model: model)) on your Sync Labs account")

        let work = scratch.appendingPathComponent("lipsync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let audio = work.appendingPathComponent("reel.wav")
        try await ffmpeg(LipSync.audioArguments(source: reel.path, output: audio.path))
        try Task.checkCancellation()

        log("Lip sync: uploading the reel…")
        // Generic names: no reel title, profile or person leaves this Mac.
        let videoAsset = try await client.upload(reel, as: "reel.mp4", contentType: "video/mp4", type: "VIDEO")
        try Task.checkCancellation()
        let audioAsset = try await client.upload(audio, as: "reel.wav", contentType: "audio/wav", type: "AUDIO")
        try Task.checkCancellation()

        var generation = try await client.generate(LipSync.request(videoAsset: videoAsset, audioAsset: audioAsset, model: model),
                                                   idempotencyKey: UUID().uuidString)
        log("Lip sync: Sync Labs is re-timing the mouths…")
        let started = Date()
        var synced: URL?
        waiting: while true {
            switch LipSync.outcome(generation) {
            case .done(let url):
                synced = url
                break waiting
            case .unchanged(let reason):
                return .unchanged(reason)
            case .failed(let reason):
                throw SyncLabsError.failed("Sync Labs could not lip-sync this reel: \(reason)")
            case .waiting:
                guard Date().timeIntervalSince(started) < timeoutSeconds else { throw SyncLabsError.timedOut }
                try await Task.sleep(for: .seconds(pollSeconds))
                generation = try await client.generation(generation.id)
            }
        }
        guard let synced else { throw SyncLabsError.failed("Sync Labs finished without a video to download.") }

        log("Lip sync: downloading the result…")
        let downloaded = work.appendingPathComponent("synced.mp4")
        try await client.download(synced, to: downloaded)
        try Task.checkCancellation()
        // Measured before the mux: the reel's own audio would lend a short picture its length.
        let length = await pictureDuration(downloaded)
        guard LipSync.sameLength(length, as: seconds) else {
            throw SyncLabsError.failed("The synced video is \(LipSync.length(length)) long and the reel is \(LipSync.length(seconds)); the reel was kept as it was.")
        }
        let muxed = work.appendingPathComponent("muxed.mp4")
        try await ffmpeg(LipSync.muxArguments(synced: downloaded.path, original: reel.path, output: muxed.path))
        guard LipSync.sameLength(await pictureDuration(muxed), as: seconds) else {
            throw SyncLabsError.failed("The synced video could not be joined with the reel's audio; the reel was kept as it was.")
        }
        // Staged beside the reel and swapped in one step: a failed copy never costs the reel.
        let staged = reel.deletingLastPathComponent().appendingPathComponent(".lipsync-\(UUID().uuidString).mp4")
        do {
            try FileManager.default.copyItem(at: muxed, to: staged)
            try Task.checkCancellation()
            _ = try FileManager.default.replaceItemAt(reel, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return .synced
    }
}
