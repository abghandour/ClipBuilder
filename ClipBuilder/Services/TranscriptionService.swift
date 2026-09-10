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

    init(cacheDirectory: URL = SettingsStore.cacheDirectory.appendingPathComponent("transcripts", isDirectory: true)) {
        self.cacheDirectory = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Shared entry point for manual and batch transcription.
    @discardableResult
    func transcribeForVideo(video: VideoRecord, database: Database,
                            languageCode: String = "", force: Bool = false,
                            log: @Sendable (String) -> Void) async throws -> [TranscriptSegment] {
        if video.type == .podcast {
            return try await transcribePodcast(video: video, database: database,
                                               languageCode: languageCode, force: force, log: log)
        }
        return try await transcribe(video: video, database: database,
                                    languageCode: languageCode, force: force, log: log)
    }

    func cachedPodcast(video: VideoRecord, force: Bool) throws -> CachedTranscript? {
        guard !force else { return nil }
        let hash = String(try SourceIdentityCache.shared.fingerprint(of: video.url).prefix(32))
        let prefix = "\(hash).\(Self.providerName).\(Self.modelName)."
        let files = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let cached = try? JSONDecoder().decode(CachedTranscript.self, from: data),
                  cached.provider == Self.providerName, cached.model == Self.modelName,
                  !cached.translate else { continue }
            return cached
        }
        return nil
    }

    private func restore(_ cached: CachedTranscript, video: VideoRecord, database: Database,
                         log: @Sendable (String) -> Void) async throws -> [TranscriptSegment] {
        log("Using cached transcript for \(video.filename)")
        try await database.replaceTranscripts(videoID: video.id, language: cached.detectedLanguage,
                                              isTranslation: false, segments: cached.segments,
                                              provider: Self.providerName, model: Self.modelName)
        do { try await enrich(cached.segments, video: video, database: database) }
        catch { log("Transcript feature analysis failed: \(error)") }
        return cached.segments
    }

    /// English and Brazilian Portuguese are the fast path. Installed
    /// recognizers are considered only when neither primary recognizer can
    /// make a credible transcript.
    nonisolated static func choosePodcastLanguage(
        primary: [PodcastLanguageCandidate],
        installed: [PodcastLanguageCandidate] = [],
        lowConfidence: Double = 0.45
    ) -> PodcastLanguageCandidate? {
        let bestPrimary = primary.max { $0.confidence < $1.confidence }
        if let bestPrimary, bestPrimary.confidence >= lowConfidence { return bestPrimary }
        return (primary + installed).max { $0.confidence < $1.confidence }
    }

    /// Podcast transcription always auto-detects unless the user explicitly
    /// selected a language. Detection examines only the first minute.
    @discardableResult
    func transcribePodcast(video: VideoRecord, database: Database,
                           languageCode: String = "", force: Bool = false,
                           log: @Sendable (String) -> Void) async throws -> [TranscriptSegment] {
        if !languageCode.isEmpty {
            return try await transcribe(video: video, database: database,
                                        languageCode: languageCode, force: force, log: log)
        }
        if let cached = try cachedPodcast(video: video, force: force) {
            return try await restore(cached, video: video, database: database, log: log)
        }
        guard await FFmpeg.hasAudioStream(video.url) else {
            throw TranscriptionError.noAudioTrack(video.filename)
        }
        let sampleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb_language_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: sampleURL) }
        // Warm runs sample the artifact; cold runs keep the fast direct minute.
        let sampleSource = try await NormalizedAudioCache.shared.existing(source: video.url) ?? video.url
        try await FFmpeg.run(["-y", "-i", sampleSource.path, "-t", "60", "-vn",
                              "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                              sampleURL.path], timeout: 180)

        var primary: [PodcastLanguageCandidate] = []
        var tried = Set<String>()
        // Keep serial: candidates can install shared Speech assets, and the
        // existing collector's failure/cancellation ordering is sequential.
        for identifier in ["en-US", "pt-BR"] {
            guard let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: identifier)) else { continue }
            tried.insert(locale.identifier)
            do {
                let result = try await Self.runSpeechTranscriber(audioURL: sampleURL, locale: locale)
                primary.append(PodcastLanguageCandidate(identifier: locale.identifier,
                                                         confidence: result.confidence))
                log("Language sample \(locale.identifier): \(Int(result.confidence * 100))% confidence")
            } catch {
                try Task.checkCancellation()
                log("Language sample \(locale.identifier) unavailable: \(error)")
            }
        }
        var other: [PodcastLanguageCandidate] = []
        if primary.allSatisfy({ $0.confidence < 0.45 }) {
            for locale in await SpeechTranscriber.installedLocales where !tried.contains(locale.identifier) {
                do {
                    let result = try await Self.runSpeechTranscriber(audioURL: sampleURL, locale: locale)
                    other.append(PodcastLanguageCandidate(identifier: locale.identifier,
                                                           confidence: result.confidence))
                } catch {
                    try Task.checkCancellation()
                    log("Language sample \(locale.identifier) unavailable: \(error)")
                }
            }
        }
        let chosen = Self.choosePodcastLanguage(primary: primary, installed: other)
            ?? PodcastLanguageCandidate(identifier: "en-US", confidence: 0)
        log("Detected podcast language: \(chosen.identifier)")
        return try await transcribe(video: video, database: database,
                                    languageCode: chosen.identifier, force: force, log: log)
    }

    nonisolated struct CachedTranscript: Codable {
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
        let hash = String(try SourceIdentityCache.shared.fingerprint(of: video.url).prefix(32))
        let cacheURL = cacheDirectory.appendingPathComponent(
            "\(hash).\(Self.providerName).\(Self.modelName).\(languageTag).json")

        if !force, let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(CachedTranscript.self, from: data) {
            return try await restore(cached, video: video, database: database, log: log)
        }

        guard await FFmpeg.hasAudioStream(video.url) else {
            throw TranscriptionError.noAudioTrack(video.filename)
        }

        log("Preparing audio from \(video.filename)...")
        // Timed from audio preparation: that is the wait the user sees.
        let started = ContinuousClock.now
        let audioURL = try await NormalizedAudioCache.shared.audio(source: video.url)

        log("Transcribing \(video.filename) (\(supportedLocale.identifier))...")
        let segments = try await Self.runSpeechTranscriber(audioURL: audioURL, locale: supportedLocale).segments
        let seconds = (ContinuousClock.now - started).seconds
        log("Transcribed \(segments.count) segments in \(AIProvenance.durationLabel(seconds))")

        let cached = CachedTranscript(provider: Self.providerName, model: Self.modelName,
                                      language: languageTag, detectedLanguage: languageTag,
                                      translate: false, segments: segments)
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: cacheURL)
        }

        try await database.replaceTranscripts(videoID: video.id, language: languageTag,
                                              isTranslation: false, segments: segments,
                                              provider: Self.providerName, model: Self.modelName,
                                              seconds: seconds)
        do { try await enrich(segments, video: video, database: database) }
        catch { log("Transcript feature analysis failed: \(error)") }
        return segments
    }

    private func enrich(_ segments: [TranscriptSegment], video: VideoRecord,
                        database: Database) async throws {
        let people = try await database.fetchVideoPeople(videoID: video.id)
        let scenes = try await database.fetchScenes(includeExcluded: true)
            .filter { $0.videoID == video.id }
        let settings = SettingsStore.loadSettings().podcast
        let analysis = TranscriptFeatureAnalyzer.analyze(
            segments: segments, videoID: video.id,
            speakerKeys: people.map(\.key), mediaDuration: video.duration,
            speakerHints: TranscriptFeatureAnalyzer.speakerHints(
                scenes: scenes, personKeys: people.map(\.key)),
            deadAirThreshold: settings.deadAirSeconds,
            fillerRunThreshold: settings.fillerRunSeconds)
        try await database.replaceTranscriptFeatures(videoID: video.id,
                                                     features: analysis.features,
                                                     proposals: analysis.proposals)
    }

    private static func runSpeechTranscriber(audioURL: URL, locale: Locale) async throws
        -> (segments: [TranscriptSegment], confidence: Double) {
        let timing = PerfSignpost.begin("Transcription", metadata: locale.identifier)
        defer { PerfSignpost.end(timing) }
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installationRequest.downloadAndInstall()
        }

        // AVAudioFile keeps this on the macOS 26 API surface — the
        // AssetInputSequenceProvider alternative requires macOS 27.
        let audioFile = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collect finalized results while the analyzer consumes the file.
        let collector = Task<([TranscriptSegment], [Double]), Error> {
            var segments: [TranscriptSegment] = []
            var confidences: [Double] = []
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
                    if let confidence = run.transcriptionConfidence {
                        confidences.append(confidence)
                    }
                }
                guard segmentStart < segmentEnd else { continue }
                segments.append(TranscriptSegment(start: segmentStart.rounded(toPlaces: 2),
                                                  end: segmentEnd.rounded(toPlaces: 2),
                                                  text: plain,
                                                  words: words.isEmpty ? nil : words))
            }
            return (segments, confidences)
        }

        let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
        if let lastSampleTime {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let (segments, confidences) = try await collector.value
        let confidence: Double
        if confidences.isEmpty {
            // Some installed recognizers omit confidence attributes. A
            // coherent non-empty result remains more useful than silence.
            confidence = segments.isEmpty ? 0 : 0.5
        } else {
            confidence = confidences.reduce(0, +) / Double(confidences.count)
        }
        return (segments, confidence)
    }
}
