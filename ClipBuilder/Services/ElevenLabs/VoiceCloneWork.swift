import Foundation

nonisolated enum VoiceCloneWork {
    @concurrent
    static func client() async throws -> ElevenLabsClient {
        guard let key = try ElevenLabsKeychain().read(), !key.isEmpty else { throw ElevenLabsError.invalidKey }
        return ElevenLabsClient(apiKey: key)
    }

    @concurrent
    static func extract(personKey: String, name: String, database: Database, scratch: URL,
                        log: @escaping @Sendable (String) -> Void) async throws -> [URL] {
        let videos = try await database.fetchVideos()
        var turns: [SpeakerTurn] = []
        var rows: [TranscriptRow] = []
        var sources: [Int64: URL] = [:]
        for video in videos {
            try Task.checkCancellation()
            guard let path = video.path, FileManager.default.fileExists(atPath: path) else { continue }
            // Name voice clusters the way the dub does, so footage analyzed
            // before the people pass still yields this person's turns.
            let roster = try await database.fetchVideoPeople(videoID: video.id)
            let videoTurns = DubPlanning.namingTurns(try await database.fetchSpeakerTurns(videoID: video.id),
                                                     roster: roster)
            guard videoTurns.contains(where: { $0.personKey == personKey }) else { continue }
            sources[video.id] = URL(fileURLWithPath: path)
            turns += videoTurns
            rows += try await database.fetchTranscripts(videoID: video.id)
        }
        let selection = VoiceCloneSampler.select(personKey: personKey, name: name, turns: turns, transcripts: rows)
        if let reason = selection.reason {
            throw NSError(domain: "VoiceClone", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var filenames: [String] = []
        for (index, range) in selection.ranges.enumerated() {
            try Task.checkCancellation()
            guard let source = sources[range.videoID] else { throw URLError(.fileDoesNotExist) }
            log("Extracting clean speech \(index + 1) of \(selection.ranges.count)…")
            let filename = "sample-\(index).wav"
            let output = scratch.appendingPathComponent(filename)
            // Seek before the input: a turn 35 minutes in must not decode the first 35.
            try await FFmpeg.run(["-y", "-ss", String(range.start), "-i", source.path,
                "-t", String(range.duration), "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "44100",
                "-c:a", "pcm_s16le", output.path], purpose: "Voice clone sample")
            filenames.append(filename)
        }
        try Task.checkCancellation()
        log("Joining \(Int(selection.seconds)) s of clean speech…")
        let manifest = scratch.appendingPathComponent("samples.txt")
        // Only our generated leaf names go into the concat manifest.
        try filenames.map { "file '\($0)'" }.joined(separator: "\n").write(to: manifest, atomically: true, encoding: .utf8)
        // MP3 keeps two minutes near 3 MB; the same speech as WAV is about 10.6 MB.
        let output = scratch.appendingPathComponent("voice.mp3")
        try await FFmpeg.run(["-y", "-f", "concat", "-safe", "1", "-i", manifest.path,
            "-vn", "-ac", "1", "-ar", "44100", "-c:a", "libmp3lame", "-b:a", "192k", output.path],
            purpose: "Voice clone audio")
        try Task.checkCancellation()
        return [output]
    }

    @concurrent
    static func removeScratch(_ scratch: URL) async throws {
        if FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
    }
}
