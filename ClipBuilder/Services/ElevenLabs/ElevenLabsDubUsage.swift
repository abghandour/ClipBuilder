import Synchronization

/// Per-job request accounting inherited by bounded child tasks and the shared
/// synthesizer. Cache hits and atempo conversions never record a request.
nonisolated final class ElevenLabsDubUsage: Sendable {
    @TaskLocal static var current: ElevenLabsDubUsage?

    private let characters = Mutex(0)
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) { self.log = log }

    /// The review's original lines describe the cached audio. Speaker voice
    /// overrides live in settings until Update lines applies them.
    static func pendingCharacters(lines: [DubLine], cachedLines: [DubLine], voices: [String: String]) -> Int {
        let cached = Dictionary(uniqueKeysWithValues: cachedLines.map { ($0.id, $0) })
        return lines.reduce(0) { count, line in
            let voice = voices[line.speakerKey] ?? line.voice
            if line.audio != nil, let original = cached[line.id], original.audio != nil,
               line.text == original.text, voice == original.voice {
                return count
            }
            return count + line.text.count
        }
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
        defer { log("ElevenLabs: \(usage.characters.withLock { $0 }) characters") }
        return try await $current.withValue(usage, operation: operation)
    }
}
