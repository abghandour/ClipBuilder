import Foundation
import Synchronization

/// Per-job request accounting inherited by bounded child tasks and the shared
/// synthesizer. Cache hits and atempo conversions never record a request.
nonisolated final class ElevenLabsDubUsage: Sendable {
    @TaskLocal static var current: ElevenLabsDubUsage?

    private let characters = Mutex(0)
    private let reused = Mutex(0)
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) { self.log = log }

    /// The review's original lines describe the cached audio. Speaker voice
    /// overrides live in settings until Update lines applies them.
    static func pendingCharacters(lines: [DubLine], cachedLines: [DubLine], voices: [String: String]) -> Int {
        let cached = Dictionary(uniqueKeysWithValues: cachedLines.map { ($0.id, $0) })
        return lines.reduce(0) { count, line in
            let voice = voices[line.speakerKey] ?? line.voice
            if line.draft != true, line.audio != nil, let original = cached[line.id], original.audio != nil,
               line.text == original.text, voice == original.voice {
                return count
            }
            return count + line.text.count
        }
    }

    func reuse(characters count: Int) {
        reused.withLock { $0 += count }
    }

    func request(characters count: Int) {
        characters.withLock { $0 += count }
        log("ElevenLabs request: \(count) characters")
    }

    @concurrent
    static func withLogging<T: Sendable>(enabled: Bool, log: @escaping @Sendable (String) -> Void,
                                        operation: @Sendable () async throws -> T) async rethrows -> T {
        guard enabled else { return try await operation() }
        let usage = ElevenLabsDubUsage(log: log)
        // Also report characters sent before a later error or cancellation.
        defer {
            log("ElevenLabs: \(usage.reused.withLock { $0 }) characters reused · \(usage.characters.withLock { $0 }) characters requested")
        }
        return try await $current.withValue(usage, operation: operation)
    }
}


extension ElevenLabsDubUsage {
    nonisolated struct Estimate: Sendable, Equatable {
        var characters = 0
        var reusedLines = 0
        var totalLines = 0
        var creditsPerCharacter = 1.0
        var credits: Int { Int(ceil(Double(characters) * creditsPerCharacter)) }
        var caption: String { "≈ \(credits.formatted()) credits · \(reusedLines) of \(totalLines) lines reuse earlier audio" }
    }

    @concurrent
    static func estimate(lines: [DubLine], cachedLines: [DubLine] = [], voices: [String: String],
                         database: Database?, settings: ElevenLabsSettings? = nil,
                         directory: URL = DubSynthesizer.cacheDirectory) async throws -> Estimate {
        let settings = settings ?? SettingsStore.loadSettings().ai.elevenLabs ?? ElevenLabsSettings()
        let cached = Dictionary(uniqueKeysWithValues: cachedLines.map { ($0.id, $0) })
        var result = Estimate(totalLines: lines.count, creditsPerCharacter: settings.model == "eleven_flash_v2_5" ? 0.5 : 1)
        var requested: Set<String> = []
        var byVideo: [Int64: [DubTake]] = [:]
        let folder = await database?.dubTakesDirectory
        for var line in lines {
            try Task.checkCancellation()
            line.voice = voices[line.speakerKey] ?? line.voice
            guard ElevenLabsVoices.isElevenLabs(line.voice) else { result.reusedLines += 1; continue }
            if let old = cached[line.id], old.draft != true, DubTakeCutter.normalized(old.text) == DubTakeCutter.normalized(line.text),
               old.voice == line.voice, let audio = old.audio,
               DubTakeStore.hasAudio(directory.appendingPathComponent(audio)) {
                result.reusedLines += 1
                continue
            }
            let plain = try DubSynthesizer.cacheName(language: "elevenlabs", voice: DubTake.cacheVoice(line.voice, settings: settings),
                                                      rate: 1, text: line.text)
            if line.draft != true, DubTakeStore.hasAudio(directory.appendingPathComponent(plain)) {
                result.reusedLines += 1
                continue
            }
            var count = line.text.count
            var identity = plain
            if let database, let source = DubTakeStore.requestSource(line), let folder {
                if byVideo[source.videoID] == nil { byVideo[source.videoID] = try await database.fetchDubTakes(videoID: source.videoID) }
                let take = (byVideo[source.videoID] ?? []).first {
                    DubTakeStore.matches($0, source: source, voice: line.voice, settings: settings)
                        && (DubTakeStore.hasAudio(folder.appendingPathComponent($0.audioFile))
                            || $0.driveFileID?.isEmpty == false)
                }
                if let take {
                    if DubTakeStore.fullSpan(line, source: source) || DubTakeCutter.timeRange(text: take.text, alignment: take.alignment,
                        rowStart: source.rowStart, rowEnd: source.rowEnd, start: line.sourceStart, end: line.sourceEnd, words: source.words) != nil {
                        result.reusedLines += 1
                        continue
                    }
                    // A known alignment-less row needs plain synthesis for this fragment.
                } else {
                    let hash = try await database.dubVideoHash(source.videoID)
                    identity = DubTake.key(videoHash: hash, source: source, voice: line.voice, settings: settings)
                    count = source.text.count
                }
            }
            if requested.insert(identity).inserted { result.characters += count }
            else { result.reusedLines += 1 }
        }
        return result
    }
}
