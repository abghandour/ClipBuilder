import Foundation

/// Samples use the final compositor, never a separate approximation of a
/// look. A sidecar invalidates the stable preset URL when Video A changes.
nonisolated enum LookSamples {
    static var directory: URL {
        SettingsStore.cacheDirectory.appendingPathComponent("looks", isDirectory: true)
    }

    static func previewURL(for presetID: String, directory: URL = directory,
                           rendererVersion: String = RenderSegmentCache.rendererVersion) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let name = presetID.addingPercentEncoding(withAllowedCharacters: allowed) ?? "look"
        let version = rendererVersion.addingPercentEncoding(withAllowedCharacters: allowed) ?? "version"
        return directory.appendingPathComponent("\(name)-v\(version).mp4")
    }

    static func sampleKey(video: URL?) throws -> String {
        guard let video else { return "transition-blue-square-v1" }
        // FileManager reads the file each time; URL.resourceValues caches
        // per URL instance, which returned stale size/date after a rewrite.
        let path = video.standardizedFileURL.path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return try RenderSegmentCache.key([path, String(modified), String(size)], version: "look-sample-v1")
    }

    static func hasPreview(for presetID: String, video: URL?, directory: URL = directory) -> Bool {
        let output = previewURL(for: presetID, directory: directory)
        guard let key = try? sampleKey(video: video),
              FileManager.default.fileExists(atPath: output.path),
              let saved = try? String(contentsOf: output.appendingPathExtension("sample"), encoding: .utf8) else { return false }
        return saved == key
    }

    /// Public entry point also serializes requests from different windows.
    static func preview(for presetID: String, video: URL? = EffectSampleSet.saved.videoA,
                        profile: BrandProfile, database: Database) async throws -> URL {
        try await queue.preview(presetID: presetID, video: video, profile: profile,
                                database: database, directory: directory)
    }

    private static let queue = LookSampleQueue()

    static func document(source: URL, duration: Double, presetID: String, wide: Bool) -> TimelineDocument {
        var clip = TimelineClip()
        clip.videoFile = source.path
        clip.sourceStart = 0
        clip.sourceEnd = duration
        clip.duration = duration
        clip.muted = true
        clip.wide = wide
        clip.cropXFrac = wide ? 0.5 : nil
        var document = TimelineDocument()
        document.videoTrack = [clip]
        document.trackSettings[0].effect = presetID == "none" ? nil : EffectSpec(preset: presetID)
        document.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: duration)]
        return document
    }

    @concurrent
    fileprivate static func renderSample(presetID: String, video: URL?, profile: BrandProfile,
                                         database: Database, directory: URL) async throws -> URL {
        try Task.checkCancellation()
        guard EffectCatalog.isAvailable(presetID) else {
            throw NSError(domain: "LookSamples", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This look needs a filter or LUT that is unavailable locally."])
        }
        if hasPreview(for: presetID, video: video, directory: directory) {
            return previewURL(for: presetID, directory: directory)
        }
        let key = try sampleKey(video: video)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb_look_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source: URL
        if let video {
            source = video
        } else {
            source = scratch.appendingPathComponent("card.mp4")
            try await testCard(output: source)
        }
        let duration = min(3, await FFmpeg.duration(of: source))
        guard duration.isFinite, duration > 0 else {
            throw NSError(domain: "LookSamples", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The sample video has no playable duration. Choose another sample."])
        }
        let dimensions = await FFmpeg.dimensions(of: source)
        let document = document(source: source, duration: duration, presetID: presetID,
                                wide: dimensions.width > dimensions.height)
        let renderer = MultitrackRenderer(render: RenderEngine(),
                                         segmentCache: RenderSegmentCache(directory: scratch.appendingPathComponent("segments")))
        let result = try await renderer.render(document: document, scenes: [], profile: profile,
                                               database: database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: result.url) }
        try Task.checkCancellation()
        let output = previewURL(for: presetID, directory: directory)
        let stamp = output.appendingPathExtension("sample")
        // Remove the receipt first: an interrupted replacement cannot be
        // mistaken for a completed sample on the next visit.
        if FileManager.default.fileExists(atPath: stamp.path) {
            try FileManager.default.removeItem(at: stamp)
        }
        try FileManager.default.copyItemReplacing(at: result.url, to: output)
        try key.write(to: stamp, atomically: true, encoding: .utf8)
        return output
    }

    /// The same blue square test card as TransitionCatalog's Video A.
    /// Kept here so the transition renderer's private API stays untouched.
    private static func testCard(output: URL) async throws {
        let w = RenderEngine.outputWidth
        let h = RenderEngine.outputHeight
        let color = "0x2563EB"
        let duration = EffectPreviewRenderer.cardDuration
        let marks = [
            "drawbox=x=\(w / 2 - 300):y=\(h / 2 - 300):w=600:h=600:color=white@0.92:t=fill",
            "drawbox=x=\(w / 2 - 180):y=\(h / 2 - 180):w=360:h=360:color=\(color):t=fill",
            "drawbox=x=24:y=24:w=\(w - 48):h=\(h - 48):color=white@0.5:t=8"
        ]
        var arguments = ["-y", "-f", "lavfi", "-i", "color=c=\(color):s=\(w)x\(h):d=\(duration):r=30",
                         "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                         "-filter_complex", "[0:v]" + marks.joined(separator: ",") + ",setsar=1,fps=30[vout]",
                         "-map", "[vout]", "-map", "1:a", "-t", String(duration)]
        arguments += FFmpeg.encodeArgs
        arguments.append(output.path)
        _ = try await FFmpeg.run(arguments, timeout: 120)
    }
}

/// Chaining tasks keeps the whole asynchronous render/cache publication
/// serialized despite actor reentrancy, including rapid sample changes.
private actor LookSampleQueue {
    private var tail: Task<URL, Error>?
    private var generation = 0

    func preview(presetID: String, video: URL?, profile: BrandProfile,
                 database: Database, directory: URL) async throws -> URL {
        let previous = tail
        generation += 1
        let current = generation
        let task = Task {
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            return try await LookSamples.renderSample(presetID: presetID, video: video,
                                                       profile: profile, database: database, directory: directory)
        }
        tail = task
        defer { if current == generation { tail = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
