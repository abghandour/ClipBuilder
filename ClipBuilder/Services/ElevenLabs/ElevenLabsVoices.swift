import Foundation

nonisolated enum ElevenLabsVoices {
    static let identifierPrefix = "elevenlabs:"
    /// Appended to the person's name when the app uploads a clone.
    static let cloneNameSuffix = " (Clip Builder)"
    /// The account's own voices, where voices are added and cloned.
    static let manageURL = URL(string: "https://elevenlabs.io/app/voice-lab")!
    /// Settings posts this on the main actor after changing the key or checking the account.
    static let settingsChanged = Notification.Name("ElevenLabsSettingsChanged")
    static let supportedLanguages = [
        "en", "ja", "zh", "de", "hi", "fr", "ko", "pt", "it", "es", "id", "nl", "tr", "fil", "pl", "sv",
        "bg", "ro", "ar", "cs", "el", "fi", "hr", "ms", "sk", "da", "ta", "uk", "ru", "hu", "no", "vi",
    ]

    static func isElevenLabs(_ identifier: String) -> Bool { identifier.hasPrefix(identifierPrefix) }

    static func voiceID(_ identifier: String) -> String? {
        guard isElevenLabs(identifier) else { return nil }
        let id = String(identifier.dropFirst(identifierPrefix.count))
        return id.isEmpty ? nil : id
    }

    static func voices(from voices: [ElevenLabsVoice], language: String) -> [DubSynthesizer.Voice] {
        DubSynthesizer.ranked(voices.map { voice in
            let gender: DubVoiceGender
            switch voice.labels?["gender"]?.lowercased() {
            case "male": gender = .male
            case "female": gender = .female
            default: gender = DubVoiceGender.inferred(voiceName: voice.name)
            }
            let cloned = ["cloned", "professional"].contains(voice.category ?? "")
            // Clones made here are uploaded as "Name (Clip Builder)" so they are
            // recognizable on elevenlabs.io; in the app "(cloned)" says enough.
            let name = cloned && voice.name.hasSuffix(cloneNameSuffix)
                ? String(voice.name.dropLast(cloneNameSuffix.count)) : voice.name
            return .init(identifier: identifierPrefix + voice.voiceID, language: language,
                         name: name + (cloned ? " (cloned)" : ""), quality: 3, gender: gender)
        })
    }
}

/// Shares one fetch (including an in-flight fetch) across all pickers this launch.
/// Check and Manage explicitly refresh; changing or removing the key discards
/// the previous account's list on the next read. Failures are cached too.
actor ElevenLabsVoiceCache {
    static let shared = ElevenLabsVoiceCache()

    private let key: @Sendable () throws -> String?
    private let client: @Sendable (String) -> ElevenLabsClient
    private var cachedKey: String?
    private var fetch: Task<[ElevenLabsVoice], Error>?

    init(key: @escaping @Sendable () throws -> String? = { try ElevenLabsKeychain().read() },
         client: @escaping @Sendable (String) -> ElevenLabsClient = { ElevenLabsClient(apiKey: $0) }) {
        self.key = key
        self.client = client
    }

    func voices() async throws -> [ElevenLabsVoice] {
        let currentKey: String?
        do {
            currentKey = try key()
        } catch {
            invalidate()
            throw error
        }
        if currentKey != cachedKey { invalidate() }
        guard let currentKey, !currentKey.isEmpty else { throw ElevenLabsError.invalidKey }
        cachedKey = currentKey
        if let fetch { return try await fetch.value }
        let client = client(currentKey)
        let task = Task { try await client.voices() }
        fetch = task
        return try await task.value
    }

    @discardableResult
    func refresh() async throws -> [ElevenLabsVoice] {
        invalidate()
        return try await voices()
    }

    func invalidate() {
        fetch?.cancel()
        fetch = nil
        cachedKey = nil
    }
}
