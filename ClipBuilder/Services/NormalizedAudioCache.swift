import Foundation

/// Shared source decode for transcription and diarization. Only completed WAVs
/// are published; each producer owns its temporary file through cancellation.
actor NormalizedAudioCache {
    static let shared = NormalizedAudioCache()

    func existing(source: URL) throws -> URL? {
        let cache = SourceIdentityCache.shared
        let fingerprint = try cache.fingerprint(of: source)
        let url = artifactURL(cache: cache, fingerprint: fingerprint)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func audio(source: URL) async throws -> URL {
        try Task.checkCancellation()
        let cache = SourceIdentityCache.shared
        let fingerprint = try cache.fingerprint(of: source)
        let destination = artifactURL(cache: cache, fingerprint: fingerprint)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb_audio_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let temporary = scratch.appendingPathComponent("audio.wav")
        var keepTemporary = false
        defer { if !keepTemporary { try? FileManager.default.removeItem(at: scratch) } }
        try await FFmpeg.run(["-y", "-i", source.path, "-vn", "-ac", "1", "-ar", "16000",
                              "-c:a", "pcm_s16le", temporary.path], timeout: 600)
        try Task.checkCancellation()
        guard try cache.fingerprint(of: source) == fingerprint else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Source changed during audio extraction."])
        }
        // An overlapping caller may have completed while ffmpeg was running.
        do {
            try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            return destination
        } catch {
            // Cache clearing must not discard successfully extracted audio.
            // The OS owns cleanup of this private temporary directory.
            keepTemporary = true
            return temporary
        }
    }

    private func artifactURL(cache: SourceIdentityCache, fingerprint: String) -> URL {
        cache.directory.appendingPathComponent("\(fingerprint).audio-v1-16000-mono-s16.wav")
    }
}
