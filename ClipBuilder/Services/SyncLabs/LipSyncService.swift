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

    // MARK: Takes

    var fingerprint: @Sendable (URL) throws -> String = { try SourceIdentityCache.shared.fingerprint(of: $0) }
    var encoder: @Sendable () -> [String] = { FFmpeg.encodeArgs }
    var dimensions: @Sendable (URL) async -> (width: Int, height: Int) = { await FFmpeg.dimensions(of: $0) }

    /// Makes the takes that are missing and returns every one a render can
    /// read from. A stretch that fails is logged and left out: that clip
    /// renders from its source. Only cancellation and a missing key throw.
    @concurrent
    func takes(for requests: [LipSyncTakes.Request], model: LipSync.Model, scratch: URL,
               directory: URL = LipSyncTakes.directory, dubs: URL = DubSynthesizer.cacheDirectory,
               sharing: LipSyncTakeSharing? = nil,
               log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [LipSyncTakes.Substitute] {
        guard !requests.isEmpty else { return [] }
        var ready: [LipSyncTakes.Substitute] = []
        var missing: [(request: LipSyncTakes.Request, key: String)] = []
        let onDisk = LipSyncTakes.all(in: directory)
        var prints: [String: String] = [:]
        for request in requests {
            let print = try fingerprint(URL(fileURLWithPath: request.sourcePath))
            prints[request.sourcePath] = print
            let key = LipSyncTakes.key(request, sourceFingerprint: print, model: model)
            if let take = LipSyncTakes.covering(request, fingerprint: print, model: model, in: onDisk) {
                // A longer take with the same lines: nothing to buy.
                // Only this request's range was checked against its lines.
                ready.append(.init(sourcePath: request.sourcePath, sourceStart: request.sourceStart,
                                   sourceEnd: request.sourceEnd, path: LipSyncTakes.video(take.key, in: directory).path,
                                   key: take.key, takeStart: take.sourceStart))
            } else if onDisk.contains(where: { $0.key == key }) {
                // A readable sidecar with its video; a broken pair is made again.
                ready.append(.init(sourcePath: request.sourcePath, sourceStart: request.sourceStart,
                                   sourceEnd: request.sourceEnd, path: LipSyncTakes.video(key, in: directory).path, key: key,
                                   takeStart: request.sourceStart))
            } else {
                missing.append((request, key))
            }
        }
        // What this Mac already has goes to the team; what a teammate already paid for comes from it.
        if let sharing {
            for take in ready { await sharing.publish(take.key, directory) }
            if !missing.isEmpty {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let fetched = try await sharing.fetch(missing.map(\.key), directory, log)
                var usable: Set<String> = []
                let arrived = LipSyncTakes.all(in: directory)
                for item in missing where fetched.contains(item.key) {
                    // The sidecar came without a path; here it names this Mac's recording.
                    guard var take = arrived.first(where: { $0.key == item.key }) else { continue }
                    usable.insert(item.key)
                    take.sourcePath = item.request.sourcePath
                    take.fingerprint = prints[item.request.sourcePath]
                    try LipSyncTakes.write(take, in: directory)
                    ready.append(.init(sourcePath: item.request.sourcePath, sourceStart: item.request.sourceStart,
                                       sourceEnd: item.request.sourceEnd, path: LipSyncTakes.video(item.key, in: directory).path,
                                       key: item.key, takeStart: item.request.sourceStart))
                }
                if !usable.isEmpty {
                    missing.removeAll { usable.contains($0.key) }
                    log("Lip sync: \(usable.count) clips came from your team's shared takes")
                    NotificationCenter.default.post(name: LipSyncTakes.changed, object: nil)
                }
            }
        }
        let reused = ready.reduce(0) { $0 + ($1.sourceEnd - $1.sourceStart) }
        let owed = missing.reduce(0) { $0 + $1.request.seconds }
        if missing.isEmpty {
            log("Lip sync: all \(ready.count) clips reuse earlier takes (\(LipSync.length(reused))); nothing sent to Sync Labs")
            return ready
        }
        // Takes already on disk are used whatever happens to the missing ones.
        guard let key = (try? key())?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            log("Lip sync: \(missing.count) clips kept without it: \(SyncLabsError.missingKey.localizedDescription)")
            return ready
        }
        let client = client(key)
        let limit: Double?
        do {
            limit = try await client.account().limits?.maxOutputDurationSeconds
        } catch {
            try Task.checkCancellation()
            log("Lip sync: \(missing.count) clips kept without it: \(error.localizedDescription)")
            return ready
        }
        log("Lip sync with \(model.label): \(missing.count) of \(requests.count) clips to make, \(LipSync.length(owed)), "
            + "\(LipSync.estimateLabel(seconds: owed, model: model)) on your Sync Labs account"
            + (ready.isEmpty ? "" : "; \(ready.count) reuse earlier takes (\(LipSync.length(reused)))"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, item) in missing.enumerated() {
            try Task.checkCancellation()
            let request = item.request
            do {
                if let limit, limit > 0, request.seconds > limit + 0.5 {
                    throw SyncLabsError.tooLong(seconds: request.seconds, limit: limit)
                }
                log("Lip sync: clip \(index + 1) of \(missing.count) (\(LipSync.length(request.seconds)))…")
                try await make(request, key: item.key, fingerprint: prints[request.sourcePath], model: model,
                               client: client, scratch: scratch, directory: directory, dubs: dubs)
                await sharing?.publish(item.key, directory)
                ready.append(.init(sourcePath: request.sourcePath, sourceStart: request.sourceStart,
                                   sourceEnd: request.sourceEnd, path: LipSyncTakes.video(item.key, in: directory).path, key: item.key,
                                   takeStart: request.sourceStart))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Stop during an upload or download surfaces as URLError.cancelled.
                try Task.checkCancellation()
                log("Lip sync: clip \(index + 1) kept without it: \(error.localizedDescription)")
            }
            log("PROGRESS: \(Double(index + 1) / Double(missing.count))")
        }
        return ready
    }

    private func make(_ request: LipSyncTakes.Request, key: String, fingerprint: String?, model: LipSync.Model, client: SyncLabsClient,
                      scratch: URL, directory: URL, dubs: URL) async throws {
        let work = scratch.appendingPathComponent("lipsync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let picture = work.appendingPathComponent("clip.mp4"), speech = work.appendingPathComponent("clip.wav")
        try await ffmpeg(LipSyncTakes.pictureArguments(source: request.sourcePath, start: request.sourceStart,
            seconds: request.seconds, output: picture.path, encoder: encoder()))
        try await ffmpeg(LipSyncTakes.speechArguments(
            cues: request.cues.map { (dubs.appendingPathComponent($0.audio).path, $0) },
            seconds: request.seconds, output: speech.path))
        try Task.checkCancellation()
        let seconds = await pictureDuration(picture)
        guard seconds > 0 else { throw SyncLabsError.failed("The clip could not be cut for lip sync.") }
        // Generic names: no title, profile or person leaves this Mac.
        let videoAsset = try await client.upload(picture, as: "clip.mp4", contentType: "video/mp4", type: "VIDEO")
        try Task.checkCancellation()
        let audioAsset = try await client.upload(speech, as: "clip.wav", contentType: "audio/wav", type: "AUDIO")
        try Task.checkCancellation()
        // The take's key is the idempotency key: a retry after a dropped connection is not billed twice.
        var generation = try await client.generate(LipSync.request(videoAsset: videoAsset, audioAsset: audioAsset, model: model),
                                                   idempotencyKey: key)
        let started = Date()
        var synced: URL?
        waiting: while true {
            switch LipSync.outcome(generation) {
            case .done(let url):
                synced = url
                break waiting
            case .unchanged(let reason):
                throw SyncLabsError.failed("Sync Labs changed nothing: \(reason)")
            case .failed(let reason):
                throw SyncLabsError.failed("Sync Labs could not lip-sync this clip: \(reason)")
            case .waiting:
                guard Date().timeIntervalSince(started) < timeoutSeconds else { throw SyncLabsError.timedOut }
                try await Task.sleep(for: .seconds(pollSeconds))
                generation = try await client.generation(generation.id)
            }
        }
        guard let synced else { throw SyncLabsError.failed("Sync Labs finished without a video to download.") }
        let downloaded = work.appendingPathComponent("synced.mp4")
        try await client.download(synced, to: downloaded)
        try Task.checkCancellation()
        // A take stands in for the source frame for frame: a different length would slide every later frame.
        guard LipSync.sameLength(await pictureDuration(downloaded), as: seconds, tolerance: 0.1) else {
            throw SyncLabsError.failed("the synced clip came back a different length")
        }
        // Crops and cameras are measured on the source frame.
        guard await dimensions(downloaded) == dimensions(picture) else {
            throw SyncLabsError.failed("the synced clip came back at a different size")
        }
        let take = work.appendingPathComponent("take.mp4")
        try await ffmpeg(LipSyncTakes.takeArguments(synced: downloaded.path, source: request.sourcePath,
            start: request.sourceStart, seconds: request.seconds, output: take.path))
        guard LipSync.sameLength(await pictureDuration(take), as: seconds, tolerance: 0.1) else {
            throw SyncLabsError.failed("the synced clip could not be joined with its sound")
        }
        try Task.checkCancellation()
        let destination = LipSyncTakes.video(key, in: directory)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: take, to: destination)
        try LipSyncTakes.write(.init(key: key, sourcePath: request.sourcePath, sourceStart: request.sourceStart,
            sourceEnd: request.sourceEnd, model: model.rawValue, created: Date(), cues: request.cues, fingerprint: fingerprint), in: directory)
        NotificationCenter.default.post(name: LipSyncTakes.changed, object: nil)
    }
}
