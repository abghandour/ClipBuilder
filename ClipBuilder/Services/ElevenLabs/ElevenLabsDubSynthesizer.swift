import Foundation

/// Keeps the original speech at rate 1: fitting a line only runs atempo,
/// including when the first request after clearing the cache is already fitted.
actor ElevenLabsDubSynthesizer {
    static let shared = ElevenLabsDubSynthesizer()

    private let settings: @Sendable () -> ElevenLabsSettings
    private let key: @Sendable () throws -> String?
    private let client: @Sendable (String) -> ElevenLabsClient
    // Serialize identical cache entries across concurrent lines/jobs, without
    // moving requests into unstructured tasks that outlive the job's Stop.
    private var waiters: [URL: [(UUID, CheckedContinuation<Void, Error>)]] = [:]

    init(settings: @escaping @Sendable () -> ElevenLabsSettings = {
        SettingsStore.loadSettings().ai.elevenLabs ?? ElevenLabsSettings()
    }, key: @escaping @Sendable () throws -> String? = { try ElevenLabsKeychain().read() },
         client: @escaping @Sendable (String) -> ElevenLabsClient = { ElevenLabsClient(apiKey: $0) }) {
        self.settings = settings
        self.key = key
        self.client = client
    }

    func synthesize(text: String, voice: String, rate: Double, directory: URL, model: String? = nil) async throws -> URL {
        try Task.checkCancellation()
        guard let voiceID = ElevenLabsVoices.voiceID(voice) else {
            throw ScriptError.invalid("\(voice) is not an ElevenLabs voice.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rate.isFinite, rate >= 1, rate <= 1.25 else {
            throw ScriptError.invalid("A dub line needs text and a speech rate between 1 and 1.25.")
        }
        var settings = settings()
        if let model { settings.model = model }
        // Multilingual voices infer language from the text; no locale is part
        // of this API call. The model must be part of the cache identity.
        let cacheVoice = DubTake.cacheVoice(voice, settings: settings)
        let output = directory.appendingPathComponent(try DubSynthesizer.cacheName(
            language: "elevenlabs", voice: cacheVoice, rate: rate, text: text))
        let plain = directory.appendingPathComponent(try DubSynthesizer.cacheName(
            language: "elevenlabs", voice: cacheVoice, rate: 1, text: text))
        try await acquire(plain)
        defer { release(plain) }
        try Task.checkCancellation()
        if hasAudio(output) {
            if rate == 1 { ElevenLabsDubUsage.current?.reuse(characters: text.count) }
            return output
        }
        if rate == 1, hasAudio(plain) { ElevenLabsDubUsage.current?.reuse(characters: text.count) }
        if !hasAudio(plain) {
            guard let key = try key(), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ElevenLabsError.invalidKey
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Task.checkCancellation()
            ElevenLabsDubUsage.current?.request(characters: text.count)
            let audio = try await client(key).speak(text: text, voiceID: voiceID,
                                                   model: settings.model, settings: settings)
            try Task.checkCancellation()
            let spoken = directory.appendingPathComponent(UUID().uuidString + ".mp3")
            defer { try? FileManager.default.removeItem(at: spoken) }
            try audio.write(to: spoken)
            try await convert(spoken, rate: 1, to: plain, directory: directory)
        }
        if output != plain {
            try await convert(plain, rate: rate, to: output, directory: directory)
        }
        try Task.checkCancellation()
        return output
    }

    private func hasAudio(_ url: URL) -> Bool {
        (try? DubSynthesizer.fileDuration(of: url)) ?? 0 > 0
    }

    private func convert(_ input: URL, rate: Double, to output: URL, directory: URL) async throws {
        try Task.checkCancellation()
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await FFmpeg.run(SiriDubSynthesizer.conversionArguments(input: input, output: temporary, rate: rate),
                             timeout: SiriDubSynthesizer.timeout, purpose: "ElevenLabs dub line")
        try Task.checkCancellation()
        guard try DubSynthesizer.fileDuration(of: temporary) > 0 else {
            throw ScriptError.invalid("The ElevenLabs voice returned an empty dub line.")
        }
        if !hasAudio(output) {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: temporary, to: output)
        }
    }

    private func acquire(_ url: URL) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if waiters[url] == nil {
                waiters[url] = []
                return
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[url, default: []].append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, url: url) }
        }
    }

    private func release(_ url: URL) {
        guard var queued = waiters[url], !queued.isEmpty else {
            waiters[url] = nil
            return
        }
        let next = queued.removeFirst()
        waiters[url] = queued
        next.1.resume()
    }

    private func cancelWaiter(_ id: UUID, url: URL) {
        guard let index = waiters[url]?.firstIndex(where: { $0.0 == id }),
              let waiter = waiters[url]?.remove(at: index) else { return }
        waiter.1.resume(throwing: CancellationError())
    }
}
