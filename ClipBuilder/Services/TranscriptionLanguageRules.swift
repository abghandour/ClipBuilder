import Foundation

/// Pure rules for guessing and checking a video's spoken language. Detection
/// listens to several windows spread over the file, not just the opening
/// minute: an English intro over a Portuguese talk must not pick English.
/// Coverage says whether a recognizer actually followed the speech.
nonisolated enum TranscriptionLanguageRules {
    struct Window: Equatable, Sendable {
        var start: Double
        var length: Double
    }

    /// Where detection samples: the first minute of a short file, otherwise
    /// three 20-second windows at the first, middle and last parts of the
    /// file, so a different language later on is heard.
    static func sampleWindows(duration: Double, sampleSeconds: Double = 60) -> [Window] {
        guard duration >= sampleSeconds * 1.5 else { return [Window(start: 0, length: sampleSeconds)] }
        let length = sampleSeconds / 3
        return [0.1, 0.45, 0.8].map { fraction in
            Window(start: min(max(0, duration * fraction), duration - length), length: length)
        }
    }

    /// The ffmpeg arguments that read those windows and join them into one
    /// mono 16 kHz sample at `output`. Each window is its own seeked input,
    /// so a window late in a long file does not decode everything before it.
    static func sampleArguments(windows: [Window], source: String, output: String) -> [String] {
        let inputs = windows.flatMap { ["-ss", format($0.start), "-t", format($0.length), "-i", source] }
        let filter = windows.indices.map { "[\($0):a]" }.joined() + "concat=n=\(windows.count):v=0:a=1[out]"
        return ["-y"] + inputs + ["-vn", "-filter_complex", filter, "-map", "[out]",
                                  "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", output]
    }

    /// Seconds the windows add up to: the duration a sample's coverage is
    /// measured against.
    static func sampleLength(_ windows: [Window]) -> Double {
        windows.reduce(0) { $0 + $1.length }
    }

    /// Which other language deserves a full pass after a thin transcript,
    /// judged on the sample alone: the candidate must follow clearly more
    /// of the sample than the language already used did. Crowd noise with
    /// a few real announcements beats nothing, so nothing is retried.
    static func betterLanguage(baseline: Double, candidates: [(identifier: String, coverage: Double)],
                               minimumCoverage: Double = 0.1, margin: Double = 2) -> String? {
        guard let best = candidates.max(by: { $0.coverage < $1.coverage }),
              best.coverage >= minimumCoverage, best.coverage >= baseline * margin else { return nil }
        return best.identifier
    }

    /// The share of the file a transcript's segments cover, clamped to 0...1.
    static func coverage(segments: [TranscriptSegment], duration: Double) -> Double {
        guard duration > 0 else { return segments.isEmpty ? 0 : 1 }
        let spoken = segments.reduce(0) { $0 + max(0, $1.end - $1.start) }
        return min(1, spoken / duration)
    }

    /// Whether a transcript is too thin to trust the language it was made
    /// in: one recognized second over a minutes-long talk is the wrong
    /// recognizer, not a quiet file. Short files are left alone.
    static func shouldRetryInOtherLanguages(coverage: Double, duration: Double,
                                            minimumDuration: Double = 30, minimumCoverage: Double = 0.1) -> Bool {
        duration >= minimumDuration && coverage < minimumCoverage
    }

    /// Whether a stored original transcript is this video's transcript.
    /// Not when the user chose a language for the video and the rows are in
    /// another one, and not when it is too thin to have followed the speech
    /// (a wrong-language pass that caught a second or two). Such rows are
    /// transcribed again instead of being kept as "done".
    static func transcriptUsable(language: String?, spokenSeconds: Double, video: VideoRecord) -> Bool {
        if video.languageSource == VideoLanguage.Source.user.rawValue,
           let chosen = video.language, !chosen.isEmpty, let stored = language, !stored.isEmpty,
           Locale(identifier: chosen).language.languageCode != Locale(identifier: stored).language.languageCode {
            return false
        }
        let coverage = video.duration > 0 ? min(1, spokenSeconds / video.duration) : 1
        return !shouldRetryInOtherLanguages(coverage: coverage, duration: video.duration)
    }

    static func transcriptUsable(rows: [TranscriptRow], video: VideoRecord) -> Bool {
        let originals = rows.filter { !$0.isTranslation }
        guard !originals.isEmpty else { return false }
        return transcriptUsable(language: originals.first?.language,
                                spokenSeconds: originals.reduce(0) { $0 + max(0, $1.endTime - $1.startTime) }, video: video)
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }
}
