import Foundation
import AVFoundation
import Speech

nonisolated enum TranscriptionError: Error, CustomStringConvertible {
    case noAudioTrack(String)
    case unsupportedLocale(String)

    var description: String {
        switch self {
        case .noAudioTrack(let name): return "\(name) has no audio track to transcribe"
        case .unsupportedLocale(let locale): return "Transcription is not available for locale '\(locale)'"
        }
    }
}

/// On-device transcription with Apple's SpeechAnalyzer/SpeechTranscriber
/// (replaces faster-whisper). Results are cached on disk using the same
/// content-hash key scheme as transcription.py and written to the
/// `transcripts` table with word-level timestamps.
actor TranscriptionService {
    static let providerName = "apple"
    static let modelName = "SpeechTranscriber"

    private let cacheDirectory: URL

    init() {
        cacheDirectory = SettingsStore.cacheDirectory.appendingPathComponent("transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private nonisolated struct CachedTranscript: Codable {
        var provider: String
        var model: String
        var language: String
        var detectedLanguage: String
        var translate: Bool
        var segments: [TranscriptSegment]

        enum CodingKeys: String, CodingKey {
            case provider, model, language, translate, segments
            case detectedLanguage = "detected_language"
        }
    }

    /// Transcribe a video and persist segments into the profile database.
    /// `languageCode` empty = current locale. Returns the segments.
    @discardableResult
    func transcribe(video: VideoRecord,
                    database: Database,
                    languageCode: String = "",
                    force: Bool = false,
                    log: @Sendable (String) -> Void) async throws -> [TranscriptSegment] {
        let locale = languageCode.isEmpty ? Locale.current : Locale(identifier: languageCode)
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        }
        let languageTag = supportedLocale.language.languageCode?.identifier ?? supportedLocale.identifier

        // Cache key mirrors transcription.py: hash32.provider.model.language.json
        let hash = String(try ContentHash.fingerprint(of: video.url).prefix(32))
        let cacheURL = cacheDirectory.appendingPathComponent(
            "\(hash).\(Self.providerName).\(Self.modelName).\(languageTag).json")

        if !force, let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(CachedTranscript.self, from: data) {
            log("Using cached transcript for \(video.filename)")
            try await database.replaceTranscripts(videoID: video.id, language: cached.detectedLanguage,
                                                  isTranslation: false, segments: cached.segments,
                                                  provider: Self.providerName, model: Self.modelName)
            return cached.segments
        }

        guard await FFmpeg.hasAudioStream(video.url) else {
            throw TranscriptionError.noAudioTrack(video.filename)
        }

        // Extract 16 kHz mono audio, same command as transcription.py.
        log("Extracting audio from \(video.filename)...")
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb_audio_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try await FFmpeg.run(["-y", "-i", video.url.path,
                              "-vn", "-ac", "1", "-ar", "16000",
                              "-c:a", "aac", "-b:a", "64k", audioURL.path],
                             timeout: 600)

        log("Transcribing \(video.filename) (\(supportedLocale.identifier))...")
        let segments = try await Self.runSpeechTranscriber(audioURL: audioURL, locale: supportedLocale)
        log("Transcribed \(segments.count) segments")

        let cached = CachedTranscript(provider: Self.providerName, model: Self.modelName,
                                      language: languageTag, detectedLanguage: languageTag,
                                      translate: false, segments: segments)
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: cacheURL)
        }

        try await database.replaceTranscripts(videoID: video.id, language: languageTag,
                                              isTranslation: false, segments: segments,
                                              provider: Self.providerName, model: Self.modelName)
        return segments
    }

    private static func runSpeechTranscriber(audioURL: URL, locale: Locale) async throws -> [TranscriptSegment] {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installationRequest.downloadAndInstall()
        }

        let asset = AVURLAsset(url: audioURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscriptionError.noAudioTrack(audioURL.lastPathComponent)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        }
        let provider = AssetInputSequenceProvider(asset: asset, track: track, analyzerFormat: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collect finalized results while the analyzer consumes the file.
        let collector = Task<[TranscriptSegment], Error> {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = result.text
                let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !plain.isEmpty else { continue }

                var words: [TranscriptWord] = []
                var segmentStart = Double.greatestFiniteMagnitude
                var segmentEnd = 0.0
                for run in text.runs {
                    guard let timeRange = run.audioTimeRange else { continue }
                    let start = timeRange.start.seconds
                    let end = timeRange.end.seconds
                    let runText = String(text[run.range].characters)
                    guard !runText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    segmentStart = min(segmentStart, start)
                    segmentEnd = max(segmentEnd, end)
                    words.append(TranscriptWord(word: runText, start: start.rounded(toPlaces: 2),
                                                end: end.rounded(toPlaces: 2)))
                }
                guard segmentStart < segmentEnd else { continue }
                segments.append(TranscriptSegment(start: segmentStart.rounded(toPlaces: 2),
                                                  end: segmentEnd.rounded(toPlaces: 2),
                                                  text: plain,
                                                  words: words.isEmpty ? nil : words))
            }
            return segments
        }

        let lastSampleTime = try await analyzer.analyzeSequence(provider.analyzerInputs)
        if let lastSampleTime {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}
