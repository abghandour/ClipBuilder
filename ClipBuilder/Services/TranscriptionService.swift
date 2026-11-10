import Foundation
import AVFoundation
import Speech

nonisolated enum TranscriptionError: Error, CustomStringConvertible {
    case noAudioTrack(String)
    case unsupportedLocale(String)
    case noSpeech(String, locale: String)

    var description: String {
        switch self {
        case .noAudioTrack(let name): return "\(name) has no audio track to transcribe"
        case .noSpeech(let name, let locale):
            return "No speech was recognized in \(name) (\(locale)). Check the project’s spoken languages and that the file has spoken audio, then transcribe again."
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
    private let capturedPodcastSettings: PodcastSettings?
    private let strictEnrichment: Bool
    private let spokenLocales: [String]
    private let wordTiming: WordTiming

    init(cacheDirectory: URL = SettingsStore.cacheDirectory.appendingPathComponent("transcripts", isDirectory: true),
         podcastSettings: PodcastSettings? = nil, strictEnrichment: Bool = false, spokenLocales: [String] = [],
         wordTiming: WordTiming = .recognizer) {
        self.spokenLocales = spokenLocales
        self.wordTiming = wordTiming
        capturedPodcastSettings = podcastSettings
        self.strictEnrichment = strictEnrichment
        self.cacheDirectory = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Shared entry point for manual and batch transcription.
    @discardableResult
    func transcribeForVideo(video: VideoRecord, database: Database,
                            languageCode: String = "", force: Bool = false,
                            log: @Sendable (String) -> Void) async throws -> (segments: [TranscriptSegment], transcriptionKey: String) {
        // Several project languages and no explicit choice: sample them the
        // way podcasts do instead of falling back to the Mac's locale.
        let candidates = AnalysisRequestContext.current?.spokenLocales ?? spokenLocales
        if video.type?.usesPodcastPass == true || (languageCode.isEmpty && ProjectLanguageResolver.unique(candidates).count > 1) {
            return try await transcribePodcast(video: video, database: database,
                                               languageCode: languageCode, force: force, log: log)
        }
        return try await transcribe(video: video, database: database,
                                    languageCode: languageCode, force: force, log: log)
    }

    /// The language stored rows must be in to be reused. A project or
    /// detected language is a hint, so an existing transcript in another
    /// language (say, the one a retry settled on) stays the transcript;
    /// only a language the user chose for the video rejects it.
    nonisolated static func requiredLanguage(_ languageCode: String, video: VideoRecord) -> String {
        video.languageSource == VideoLanguage.Source.user.rawValue ? languageCode : ""
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
                  !cached.translate, !cached.segments.isEmpty else { continue }
            return cached
        }
        return nil
    }

    /// The active set's rows, when they exist and are in the language asked
    /// for (any language when none was asked): the user's edits, re-cuts and
    /// attributions live on them, so a non-forced pass never replaces them.
    private func storedTranscript(video: VideoRecord, database: Database, languageCode: String = "",
                                  log: @Sendable (String) -> Void) async throws
        -> (segments: [TranscriptSegment], transcriptionKey: String)? {
        let rows = try await database.fetchTranscripts(videoID: video.id).filter { !$0.isTranslation }
        guard let key = rows.first?.transcriptionKey else { return nil }
        guard TranscriptionLanguageRules.transcriptUsable(rows: rows, video: video) else {
            log("Stored transcript for \(video.filename) is in another language or too thin; transcribing again")
            return nil
        }
        if !languageCode.isEmpty, let stored = rows.first?.language, !stored.isEmpty,
           Locale(identifier: stored).language.languageCode != Locale(identifier: languageCode).language.languageCode {
            return nil
        }
        log("Using stored transcript for \(video.filename)")
        let segments = rows.map { TranscriptSegment(start: $0.startTime, end: $0.endTime, text: $0.text, words: $0.words) }
        do { try await enrich(segments, transcriptionKey: key, video: video, database: database) }
        catch {
            if strictEnrichment { throw error }
            log("Transcript feature analysis failed: \(error)")
        }
        return (segments, key)
    }

    private func restore(_ cached: CachedTranscript, video: VideoRecord, database: Database,
                         log: @Sendable (String) -> Void) async throws -> (segments: [TranscriptSegment], transcriptionKey: String) {
        log("Using cached transcript for \(video.filename)")
        try Task.checkCancellation()
        // The rows already stored are the user's: re-cut by speaker,
        // corrected, attributed by hand. A cache hit only fills an empty
        // transcript; otherwise the stored rows are the transcript.
        let stored = try await database.fetchTranscripts(videoID: video.id).filter { !$0.isTranslation }
        // Stored rows in another language are not this transcript: the
        // caller already rejected them, so the cached set is stored instead.
        let otherLanguage = stored.first.map { row in
            !row.language.isEmpty && !cached.detectedLanguage.isEmpty
                && Locale(identifier: row.language).language.languageCode
                    != Locale(identifier: cached.detectedLanguage).language.languageCode
        } ?? false
        let segments: [TranscriptSegment]
        let transcriptionKey: String
        if stored.isEmpty || otherLanguage {
            // The cache holds the recognizer's times; precise timing is
            // applied to what gets stored, so the setting can change later.
            let refined = try await refineTiming(cached.segments, language: cached.detectedLanguage, video: video, log: log)
            try Task.checkCancellation()
            transcriptionKey = try await Self.storeOriginal(videoID: video.id, language: cached.detectedLanguage,
                segments: refined.segments, database: database, model: refined.model)
            segments = refined.segments
        } else {
            guard let key = stored.first?.transcriptionKey else { throw ScriptError.invalid("The stored transcript has no set key.") }
            transcriptionKey = key
            segments = stored.map { TranscriptSegment(start: $0.startTime, end: $0.endTime, text: $0.text, words: $0.words) }
        }
        do { try await enrich(segments, transcriptionKey: transcriptionKey, video: video, database: database) }
        catch {
            if strictEnrichment { throw error }
            log("Transcript feature analysis failed: \(error)")
        }
        return (segments, transcriptionKey)
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
    /// selected a language. Detection samples windows across the file.
    @discardableResult
    func transcribePodcast(video: VideoRecord, database: Database,
                           languageCode: String = "", force: Bool = false,
                           log: @Sendable (String) -> Void) async throws -> (segments: [TranscriptSegment], transcriptionKey: String) {
        try video.requirePresent()
        if let key = AnalysisRequestContext.current?.transcriptKey {
            let rows = try await database.fetchTranscripts(videoID: video.id, transcriptionKey: key).filter { !$0.isTranslation }
            guard !rows.isEmpty else { throw ScriptError.invalid("The saved transcript set is not available on this Mac.") }
            return (rows.map { TranscriptSegment(start: $0.startTime, end: $0.endTime, text: $0.text, words: $0.words) }, key)
        }
        if !force, let stored = try await storedTranscript(video: video, database: database,
                                                            languageCode: Self.requiredLanguage(languageCode, video: video), log: log) { return stored }
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
        let chosen = try await detectLanguage(video: video, log: log)
            ?? PodcastLanguageCandidate(identifier: "en-US", confidence: 0)
        log("Detected podcast language: \(chosen.identifier)")
        return try await transcribe(video: video, database: database,
                                    languageCode: chosen.identifier, force: force, log: log)
    }

    /// Which language the sampled windows are spoken in: the project's spoken
    /// locales first, every installed recognizer when none of those is
    /// credible. nil when the file has no audio or no recognizer answered.
    /// The confidence lets callers ignore guesses made over crowd noise.
    /// `installedOnly` skips recognizers that are not on this Mac: a
    /// background pass must never sit in a silent asset download.
    func detectLanguage(video: VideoRecord, installedOnly: Bool = false,
                        log: @Sendable (String) -> Void) async throws -> PodcastLanguageCandidate? {
        try video.requirePresent()
        guard await FFmpeg.hasAudioStream(video.url) else { return nil }
        let installedIdentifiers = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
        let sampleURL = try await languageSample(video: video)
        defer { try? FileManager.default.removeItem(at: sampleURL) }

        var primary: [PodcastLanguageCandidate] = []
        var tried = Set<String>()
        // Keep serial: candidates can install shared Speech assets, and the
        // existing collector's failure/cancellation ordering is sequential.
        for identifier in ProjectLanguageResolver.podcastCandidates(AnalysisRequestContext.current?.spokenLocales ?? spokenLocales) {
            guard let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: identifier)) else { continue }
            if installedOnly, !installedIdentifiers.contains(locale.identifier) {
                log("Language sample \(locale.identifier) skipped: recognizer not installed")
                continue
            }
            guard tried.insert(locale.identifier).inserted else { continue }
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
        return Self.choosePodcastLanguage(primary: primary, installed: other)
    }

    /// A short mono sample of the file for language checks: several windows
    /// across the file, so an intro in another language does not decide for
    /// the whole talk. Warm runs read the normalized artifact. The caller
    /// removes the file.
    private func languageSample(video: VideoRecord) async throws -> URL {
        let sampleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb_language_\(UUID().uuidString).wav")
        let sampleSource = try await NormalizedAudioCache.shared.existing(source: video.url) ?? video.url
        let windows = TranscriptionLanguageRules.sampleWindows(duration: video.duration)
        try await FFmpeg.run(TranscriptionLanguageRules.sampleArguments(
            windows: windows, source: sampleSource.path, output: sampleURL.path),
            timeout: 180, mediaResource: .decoding)
        return sampleURL
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
                    log: @Sendable (String) -> Void) async throws -> (segments: [TranscriptSegment], transcriptionKey: String) {
        try video.requirePresent()
        if !force, let stored = try await storedTranscript(video: video, database: database,
                                                            languageCode: Self.requiredLanguage(languageCode, video: video), log: log) { return stored }
        let locale = languageCode.isEmpty ? Locale.current : Locale(identifier: languageCode)
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        }
        var languageTag = supportedLocale.language.languageCode?.identifier ?? supportedLocale.identifier

        // Cache key mirrors transcription.py: hash32.provider.model.language.json
        let hash = String(try SourceIdentityCache.shared.fingerprint(of: video.url).prefix(32))
        var cacheURL = cacheDirectory.appendingPathComponent(
            "\(hash).\(Self.providerName).\(Self.modelName).\(languageTag).json")

        // An empty cached set (older builds cached silent runs) is not a
        // transcript: ignore it and recognize again.
        if !force, let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(CachedTranscript.self, from: data),
           !cached.segments.isEmpty {
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
        var chosenLocale = supportedLocale
        var segments = try await Self.runSpeechTranscriber(audioURL: audioURL, locale: supportedLocale).segments
        var coverage = TranscriptionLanguageRules.coverage(segments: segments, duration: video.duration)
        // A recognizer in the wrong language follows a second or two and
        // drops the rest. Unless the user chose this language for the video,
        // the other project languages get a turn on a short sample, and the
        // one that clearly follows more of it gets one full pass.
        if video.languageSource != VideoLanguage.Source.user.rawValue,
           TranscriptionLanguageRules.shouldRetryInOtherLanguages(coverage: coverage, duration: video.duration) {
            log("\(supportedLocale.identifier) covered \(Int(coverage * 100))% of \(video.filename); sampling the other project languages")
            if let locale = try await betterLanguage(video: video, than: supportedLocale, log: log) {
                try Task.checkCancellation()
                log("Transcribing \(video.filename) (\(locale.identifier))...")
                do {
                    let attempt = try await Self.runSpeechTranscriber(audioURL: audioURL, locale: locale).segments
                    let attemptCoverage = TranscriptionLanguageRules.coverage(segments: attempt, duration: video.duration)
                    log("\(locale.identifier) covered \(Int(attemptCoverage * 100))%")
                    if attemptCoverage > coverage {
                        // The thin result in the first language is not this
                        // file's transcript: drop its cache so it never replays.
                        try? FileManager.default.removeItem(at: cacheURL)
                        segments = attempt
                        coverage = attemptCoverage
                        chosenLocale = locale
                        languageTag = locale.language.languageCode?.identifier ?? locale.identifier
                        cacheURL = cacheDirectory.appendingPathComponent(
                            "\(hash).\(Self.providerName).\(Self.modelName).\(languageTag).json")
                    }
                } catch {
                    try Task.checkCancellation()
                    log("\(locale.identifier) unavailable: \(error)")
                }
            }
        }
        let seconds = (ContinuousClock.now - started).seconds
        log("Transcribed \(segments.count) segments in \(AIProvenance.durationLabel(seconds))")
        // Nothing recognized is a failure, not an empty transcript: storing
        // it would log "saved" while the file stays flagged as untranscribed,
        // and caching it would replay the empty result on every retry.
        guard !segments.isEmpty else {
            try? FileManager.default.removeItem(at: cacheURL)
            throw TranscriptionError.noSpeech(video.filename, locale: chosenLocale.identifier)
        }

        let cached = CachedTranscript(provider: Self.providerName, model: Self.modelName,
                                      language: languageTag, detectedLanguage: languageTag,
                                      translate: false, segments: segments)
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: cacheURL)
        }

        try Task.checkCancellation()
        let refined = try await refineTiming(segments, language: languageTag, video: video, log: log)
        try Task.checkCancellation()
        segments = refined.segments
        let transcriptionKey = try await Self.storeOriginal(videoID: video.id, language: languageTag,
            segments: segments, database: database, seconds: seconds, model: refined.model)
        do { try await enrich(segments, transcriptionKey: transcriptionKey, video: video, database: database) }
        catch {
            if strictEnrichment { throw error }
            log("Transcript feature analysis failed: \(error)")
        }
        return (segments, transcriptionKey)
    }

    /// The installed project language that follows clearly more of a short
    /// sample than `used` did, if any. One sample pass per language bounds
    /// the cost; a failing recognizer is skipped, cancellation propagates.
    private func betterLanguage(video: VideoRecord, than used: Locale,
                                log: @Sendable (String) -> Void) async throws -> Locale? {
        let sampleURL = try await languageSample(video: video)
        defer { try? FileManager.default.removeItem(at: sampleURL) }
        let sampleLength = TranscriptionLanguageRules.sampleLength(
            TranscriptionLanguageRules.sampleWindows(duration: video.duration))
        let installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
        func sampleCoverage(_ locale: Locale) async throws -> Double? {
            do {
                let segments = try await Self.runSpeechTranscriber(audioURL: sampleURL, locale: locale).segments
                return TranscriptionLanguageRules.coverage(segments: segments, duration: sampleLength)
            } catch {
                try Task.checkCancellation()
                log("Language sample \(locale.identifier) unavailable: \(error)")
                return nil
            }
        }
        let baseline = try await sampleCoverage(used) ?? 0
        var tried: Set<String> = [used.identifier]
        var candidates: [(identifier: String, coverage: Double)] = []
        var locales: [String: Locale] = [:]
        for identifier in ProjectLanguageResolver.podcastCandidates(AnalysisRequestContext.current?.spokenLocales ?? spokenLocales) {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)),
                  installed.contains(locale.identifier), tried.insert(locale.identifier).inserted else { continue }
            guard let coverage = try await sampleCoverage(locale) else { continue }
            log("Language sample \(locale.identifier): \(Int(coverage * 100))% of the sample (\(used.identifier): \(Int(baseline * 100))%)")
            candidates.append((locale.identifier, coverage))
            locales[locale.identifier] = locale
        }
        return TranscriptionLanguageRules.betterLanguage(baseline: baseline, candidates: candidates).flatMap { locales[$0] }
    }

    /// A completed recognizer result always starts a new set. Cache hits that
    /// reuse stored rows bypass this write and retain their existing key.
    static func storeOriginal(videoID: Int64, language: String, segments: [TranscriptSegment],
                              database: Database, seconds: TimeInterval? = nil,
                              model: String = modelName) async throws -> String {
        let key = UUID().uuidString.lowercased()
        return try await database.replaceTranscripts(videoID: videoID, transcriptionKey: key,
            language: language, isTranslation: false, segments: segments,
            provider: providerName, model: model, seconds: seconds)
    }

    /// Precise word timing, when the user chose it and the aligner covers
    /// this language. The recognizer's text is never changed, and a failure
    /// here keeps the recognizer's times: a transcript is worth more than
    /// its timing.
    private func refineTiming(_ segments: [TranscriptSegment], language: String, video: VideoRecord,
                              log: @Sendable (String) -> Void) async throws -> (segments: [TranscriptSegment], model: String) {
        guard WordAlignerModel.applies(timing: wordTiming, language: language) else { return (segments, Self.modelName) }
        guard WordAlignerModel.isInstalled else {
            log("Precise word timing is on but its model is not installed; keeping the recognizer's times. Install it in Settings → Transcription.")
            return (segments, Self.modelName)
        }
        do {
            log("Refining word timing for \(video.filename)...")
            let started = ContinuousClock.now
            let audioURL = try await NormalizedAudioCache.shared.audio(source: video.url)
            // Progress lines belong to the caller's own job, not this step.
            let result = try await WordAligner.shared.retime(segments: segments, audioURL: audioURL) { _ in }
            log("Word timing refined in \(AIProvenance.durationLabel((ContinuousClock.now - started).seconds)): \(result.aligned) words placed, \(result.kept) left on recognizer time")
            // Nothing placed means the times are still the recognizer's: say so.
            return (result.segments, result.aligned > 0 ? WordAlignerModel.provenanceModel : Self.modelName)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            log("Precise word timing failed, keeping the recognizer's times: \(error)")
            return (segments, Self.modelName)
        }
    }

    /// Rebuild inexpensive derived records on this service actor, never on the UI actor.
    func refreshDerived(video: VideoRecord, database: Database, transcriptionKey: String? = nil) async throws {
        let rows = try await database.fetchTranscripts(videoID: video.id, transcriptionKey: transcriptionKey)
            .filter { !$0.isTranslation }
        guard let key = rows.first?.transcriptionKey else { return }
        let segments = rows.map { TranscriptSegment(start: $0.startTime, end: $0.endTime, text: $0.text, words: $0.words) }
        try await enrich(segments, transcriptionKey: key, video: video, database: database)
    }

    private func enrich(_ segments: [TranscriptSegment], transcriptionKey: String, video: VideoRecord,
                        database: Database) async throws {
        let people = try await database.fetchVideoPeople(videoID: video.id)
        let scenes = try await database.fetchScenes(videoID: video.id, includeExcluded: true)
        let settings = AnalysisRequestContext.current.flatMap { AISettingsJSON.decode(PodcastSettings.self, $0.podcastJSON) }
            ?? capturedPodcastSettings ?? PodcastSettings()
        let analysis = TranscriptFeatureAnalyzer.analyze(
            segments: segments, videoID: video.id,
            speakerKeys: people.map(\.key), mediaDuration: video.duration,
            speakerHints: TranscriptFeatureAnalyzer.speakerHints(
                scenes: scenes, personKeys: people.map(\.key)),
            deadAirThreshold: settings.deadAirSeconds,
            fillerRunThreshold: settings.fillerRunSeconds)
        try Task.checkCancellation()
        // Word-level cleanup reads the stored rows (their ids and timed words).
        let rows = try await database.fetchTranscripts(videoID: video.id, transcriptionKey: transcriptionKey)
            .filter { !$0.isTranslation }
        let cleanup = TranscriptCleanupProposer.editProposals(rows: rows, videoID: video.id, alongside: analysis.proposals)
        try await database.replaceTranscriptFeatures(videoID: video.id, transcriptionKey: transcriptionKey,
                                                     features: analysis.features,
                                                     proposals: settings.cleanupCutPolicy.applied(to: analysis.proposals + cleanup))
        // Topics are cheap and the Wizard plans with them: keep them current.
        try await database.replaceTopicRanges(videoID: video.id, transcriptionKey: transcriptionKey,
                                              topics: TopicSegmenter.segment(analysis.features, videoID: video.id))
    }

    /// One file through the on-device transcriber, for diagnostics
    /// (TranscriptionDiagnosticTests compares recognizers on an excerpt).
    static func transcribeFile(audioURL: URL, locale: Locale) async throws -> [TranscriptSegment] {
        try await runSpeechTranscriber(audioURL: audioURL, locale: locale).segments
    }

    /// Name hints were tried here on September 18, 2026 —
    /// AnalysisContext.contextualStrings through setContext and through the
    /// file-based initializer — and changed nothing in pt-BR output, not
    /// even names given verbatim ("Lyoto Machida" still came out "Lioto").
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
