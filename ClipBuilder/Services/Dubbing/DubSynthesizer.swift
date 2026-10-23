import AVFoundation
import CryptoKit
import Foundation
import Synchronization

/// Speech objects and utterances are created on this actor, never a UI task.
/// The system's buffer callback writes synchronously under its own lock: PCM
/// buffers are borrowed and must not be sent to an asynchronous task.
actor DubSynthesizer {
    nonisolated struct Voice: Sendable, Equatable, Identifiable {
        var identifier: String
        var language: String
        var name: String
        /// Higher is better: 3 Siri/Premium, 2 Enhanced, 1 compact, 0 Eloquence.
        var quality: Int = 1
        var gender: DubVoiceGender = .unknown
        var id: String { identifier }

        /// Novelty voices (Bells, Boing, Zarvox…) never dub anyone.
        static func isNovelty(_ identifier: String) -> Bool {
            identifier.hasPrefix("com.apple.speech.synthesis.voice.")
        }

        static func rank(identifier: String, quality: AVSpeechSynthesisVoiceQuality) -> Int {
            if identifier.contains(".siri.") || quality == .premium { return 3 }
            if quality == .enhanced { return 2 }
            if identifier.contains(".eloquence.") { return 0 }
            return 1
        }

        var qualityLabel: String? {
            SiriDubVoices.isSiri(identifier) ? "Siri" : ["Eloquence", nil, "Enhanced", "Premium"][min(3, max(0, quality))]
        }
    }

    static let shared = DubSynthesizer()
    nonisolated static var cacheDirectory: URL {
        SettingsStore.cacheDirectory.appendingPathComponent("dubs", isDirectory: true)
    }

    nonisolated static func installedVoices(language: String? = nil) -> [Voice] {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            guard let language else { return true }
            let requested = language.replacingOccurrences(of: "_", with: "-").lowercased()
            let available = voice.language.lowercased()
            return available == requested || (!requested.contains("-") && available.hasPrefix(requested + "-"))
        }.filter { !Voice.isNovelty($0.identifier) }.map {
            Voice(identifier: $0.identifier, language: $0.language, name: $0.name,
                  quality: Voice.rank(identifier: $0.identifier, quality: $0.quality),
                  gender: $0.gender == .male ? .male : $0.gender == .female ? .female : DubVoiceGender.inferred(voiceName: $0.name))
        }
        return ranked(voices)
    }

    /// Best voices first within a language, so round-robin assignment hands
    /// the Siri, Premium and Enhanced voices out before the compact ones.
    nonisolated static func ranked(_ voices: [Voice]) -> [Voice] {
        voices.sorted { ($0.language, -$0.quality, $0.name, $0.identifier) < ($1.language, -$1.quality, $1.name, $1.identifier) }
    }

    nonisolated static func cacheName(language: String, voice: String, rate: Double, text: String) throws -> String {
        // An encoded tuple avoids delimiter collisions in arbitrary text.
        let data = try JSONEncoder().encode([language, voice, String(rate), text])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".caf"
    }

    nonisolated let directory: URL
    private var active: [UUID: (AVSpeechSynthesizer, DubSpeechBufferWriter)] = [:]

    init(directory: URL = DubSynthesizer.cacheDirectory) {
        self.directory = directory
    }

    func synthesize(text: String, voice: String, rate: Double) async throws -> URL {
        try Task.checkCancellation()
        if SiriDubVoices.isSiri(voice) {
            return try await SiriDubSynthesizer.synthesize(text: text, voice: voice, rate: rate, directory: directory)
        }
        guard let installed = AVSpeechSynthesisVoice(identifier: voice) else {
            throw ScriptError.invalid("The selected Mac voice is not installed: \(voice)")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rate.isFinite, rate >= 1, rate <= 1.25 else {
            throw ScriptError.invalid("A dub line needs text and a speech rate between 1 and 1.25.")
        }
        let name = try Self.cacheName(language: installed.language, voice: voice, rate: rate, text: text)
        let output = directory.appendingPathComponent(name)
        if (try? duration(of: output)) ?? 0 > 0 { return output }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let synthesizer = AVSpeechSynthesizer()
        let writer = DubSpeechBufferWriter(url: temporary)
        let id = UUID()
        active[id] = (synthesizer, writer)
        defer { active[id] = nil }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = installed
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
        // A missing terminal callback must not strand the job indefinitely.
        let timeout = Task {
            try await Task.sleep(for: .seconds(120))
            self.cancel(id, error: ScriptError.invalid("The Mac voice did not finish the dub line."))
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.begin(continuation)
                synthesizer.write(utterance) { @Sendable buffer in writer.receive(buffer) }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancel(id, error: CancellationError()) }
        }
        guard try duration(of: temporary) > 0 else {
            throw ScriptError.invalid("The Mac voice returned an empty dub line.")
        }
        // Another request for the same utterance may have completed while we
        // awaited buffers. Publish only a closed, complete CAF.
        if (try? duration(of: output)) ?? 0 <= 0 {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: temporary, to: output)
        }
        return output
    }

    func duration(of url: URL) throws -> Double { try Self.fileDuration(of: url) }

    nonisolated static func fileDuration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Reviewed lines retain text, voice and rate. A cleared cache does not
    /// require a new translation or review, and never silently omits speech.
    func restoringAudio(lines: [DubLine]) async throws -> [DubLine] {
        var result = lines
        for index in result.indices {
            try Task.checkCancellation()
            let line = result[index]
            let cached = line.audio.flatMap { name -> URL? in
                guard name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
                return directory.appendingPathComponent(name)
            }
            let url: URL
            if let cached, (try? duration(of: cached)) ?? 0 > 0 {
                url = cached
            } else {
                url = try await synthesize(text: line.text, voice: line.voice, rate: line.rate)
            }
            result[index].audio = url.lastPathComponent
            result[index].duration = try duration(of: url) / min(1.15, max(1, line.stretch))
        }
        return result
    }

    private func cancel(_ id: UUID, error: any Error) {
        guard let (synthesizer, writer) = active[id] else { return }
        writer.finish(.failure(error))
        synthesizer.stopSpeaking(at: .immediate)
    }
}

/// Only callback state crosses executors. The lock protects the file and
/// continuation against completion, cancellation and late callback races.
private nonisolated final class DubSpeechBufferWriter: Sendable {
    private nonisolated struct State {
        var file: AVAudioFile?
        var continuation: CheckedContinuation<Void, Error>?
        var finished = false
    }

    private let state = Mutex(State())
    private let url: URL

    init(url: URL) { self.url = url }

    func begin(_ continuation: CheckedContinuation<Void, Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            finish(.failure(ScriptError.invalid("The Mac voice returned a non-PCM buffer.")))
            return
        }
        if pcm.frameLength == 0 {
            finish(.success(()))
            return
        }
        do {
            try state.withLock { state in
                guard !state.finished else { return }
                if state.file == nil {
                    state.file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                        commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                }
                try state.file?.write(from: pcm)
            }
        } catch {
            finish(.failure(error))
        }
    }

    func finish(_ result: Result<Void, Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard !state.finished else { return nil }
            state.finished = true
            state.file = nil // Close the CAF before its caller measures it.
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
