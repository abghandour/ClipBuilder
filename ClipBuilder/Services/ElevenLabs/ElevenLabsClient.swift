import Foundation

nonisolated enum ElevenLabsError: LocalizedError, Equatable {
    /// No key saved on this Mac.
    case invalidKey
    /// ElevenLabs answered 401 for the saved key: wrong key, or a restricted
    /// key without the permission this call needs (the server's message).
    case keyRejected(String?)
    case quotaExceeded(remaining: Int?)
    case tooManyRequests
    case badRequest(String)
    case http(Int)

    var userMessage: String {
        switch self {
        case .invalidKey:
            "Add your ElevenLabs key in Settings > AI"
        case .keyRejected(let message?) where message.localizedCaseInsensitiveContains("permission"):
            "ElevenLabs rejected this key: \(message) Edit the key's permissions at "
                + "elevenlabs.io › Developers › API Keys, or create a key with full access."
        case .keyRejected(let message?):
            "ElevenLabs rejected this key: \(message) Copy it again from elevenlabs.io › "
                + "Developers › API Keys and paste the whole key."
        case .keyRejected(nil):
            "ElevenLabs rejected this key. Copy it again from elevenlabs.io › Developers › "
                + "API Keys and paste the whole key."
        case .quotaExceeded(let remaining):
            "Your ElevenLabs credits for this month are used up"
                + (remaining.map { " (\($0) remaining)." } ?? ".")
                + " Check your subscription or wait for your credits to reset."
        case .tooManyRequests:
            "ElevenLabs is handling too many requests. Wait a moment and try again."
        case .badRequest(let message):
            "ElevenLabs rejected this request: \(message)"
        case .http(let status):
            "ElevenLabs returned HTTP \(status). Try again in a moment."
        }
    }

    var errorDescription: String? { userMessage }
}

nonisolated struct ElevenLabsSubscription: Decodable, Sendable, Equatable {
    var tier: String
    var characterCount: Int
    var characterLimit: Int
    var nextCharacterCountResetUnix: Int?

    enum CodingKeys: String, CodingKey {
        case tier
        case characterCount = "character_count"
        case characterLimit = "character_limit"
        case nextCharacterCountResetUnix = "next_character_count_reset_unix"
    }
}

nonisolated struct ElevenLabsVoice: Decodable, Sendable, Equatable {
    var voiceID: String
    var name: String
    var category: String?
    var labels: [String: String]?
    var verifiedLanguages: [VerifiedLanguage]?

    nonisolated struct VerifiedLanguage: Decodable, Sendable, Equatable {
        var language: String
        var locale: String?
        var accent: String?
    }

    enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id"
        case name, category, labels
        case verifiedLanguages = "verified_languages"
    }
}

nonisolated struct ElevenLabsClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let apiKey: String
    var transport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }

    func subscription() async throws -> ElevenLabsSubscription {
        let data = try await send(path: "/v1/user/subscription")
        return try JSONDecoder().decode(ElevenLabsSubscription.self, from: data)
    }

    func voices() async throws -> [ElevenLabsVoice] {
        let data = try await send(path: "/v2/voices", query: [.init(name: "page_size", value: "100")])
        return try JSONDecoder().decode(VoiceList.self, from: data).voices
    }

    func speak(text: String, voiceID: String, model: String, settings: ElevenLabsSettings) async throws -> Data {
        // Treat the id as one path component, never as a path or query supplied by a caller.
        guard !voiceID.isEmpty,
              let escaped = voiceID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw ElevenLabsError.badRequest("Choose a voice")
        }
        let body = try JSONEncoder().encode(SpeechRequest(text: text, model_id: model,
            voice_settings: .init(stability: settings.stability, similarity_boost: settings.similarity)))
        return try await send(path: "/v1/text-to-speech/" + escaped,
                              query: [.init(name: "output_format", value: "mp3_44100_128")], body: body,
                              accept: "audio/mpeg")
    }

    nonisolated struct TimestampSpeech: Decodable, Sendable {
        var audio_base64: String
        var alignment: DubTakeAlignment?
        var normalized_alignment: DubTakeAlignment?

        var audio: Data? { Data(base64Encoded: audio_base64) }
    }

    func speakWithTimestamps(text: String, voiceID: String, model: String,
                             settings: ElevenLabsSettings) async throws -> TimestampSpeech {
        guard !voiceID.isEmpty,
              let escaped = voiceID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw ElevenLabsError.badRequest("Choose a voice")
        }
        let body = try JSONEncoder().encode(SpeechRequest(text: text, model_id: model,
            voice_settings: .init(stability: settings.stability, similarity_boost: settings.similarity)))
        let data = try await send(path: "/v1/text-to-speech/" + escaped + "/with-timestamps",
            query: [.init(name: "output_format", value: "mp3_44100_128")], body: body)
        return try JSONDecoder().decode(TimestampSpeech.self, from: data)
    }

    @concurrent
    func addVoice(name: String, files: [URL], labels: [String: String],
                  removeBackgroundNoise: Bool = true) async throws -> String {
        let multipart = try ElevenLabsMultipart.voice(name: name, files: files, labels: labels,
                                                       removeBackgroundNoise: removeBackgroundNoise)
        let data = try await send(path: "/v1/voices/add", body: multipart.body,
                                  contentType: multipart.contentType, returnsCommittedResponse: true)
        let response = try JSONDecoder().decode(AddedVoice.self, from: data)
        guard !response.voice_id.isEmpty else { throw ElevenLabsError.badRequest("No voice ID returned") }
        return response.voice_id
    }

    func deleteVoice(id: String) async throws {
        guard !id.isEmpty, let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw ElevenLabsError.badRequest("Choose a voice")
        }
        _ = try await send(path: "/v1/voices/" + escaped, method: "DELETE", returnsCommittedResponse: true)
    }

    private func send(path: String, query: [URLQueryItem] = [], body: Data? = nil,
                      contentType: String = "application/json", accept: String = "application/json",
                      method: String? = nil, returnsCommittedResponse: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ElevenLabsError.invalidKey }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.elevenlabs.io"
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method ?? (body == nil ? "GET" : "POST")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        for attempt in 0...1 {
            try Task.checkCancellation()
            let data: Data, response: HTTPURLResponse
            do {
                (data, response) = try await transport(request)
            } catch {
                if !(error is CancellationError) {
                    ErrorLog.record("ElevenLabs", "\(path) did not answer: \(error.localizedDescription)")
                }
                throw error
            }
            // Keep a successful external mutation's response so its caller can
            // reconcile it (or delete the returned clone) after Stop.
            if returnsCommittedResponse, (200..<300).contains(response.statusCode) { return data }
            try Task.checkCancellation()
            if (200..<300).contains(response.statusCode) { return data }
            // The raw answer, so a rejection can be read in the console. It
            // never echoes the key, which travels only in the request header.
            let body = String(decoding: data.prefix(600), as: UTF8.self)
            ErrorLog.record("ElevenLabs", "HTTP \(response.statusCode) for \(path): \(body)")
            if response.statusCode == 429, attempt == 0 {
                try await Task.sleep(for: .seconds(2))
                continue
            }
            throw Self.error(status: response.statusCode, data: data)
        }
        throw ElevenLabsError.tooManyRequests
    }

    private static func error(status: Int, data: Data) -> ElevenLabsError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = object?["detail"] as? [String: Any]
        if detail?["status"] as? String == "quota_exceeded" {
            return .quotaExceeded(remaining: (detail?["remaining"] as? Int) ?? (detail?["remaining_credits"] as? Int))
        }
        if status == 401 || detail?["status"] as? String == "invalid_api_key" {
            let message = (detail?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // ElevenLabs says why (wrong key, missing permission); keep its words.
            return .keyRejected(message?.isEmpty == false ? message : nil)
        }
        if status == 429 { return .tooManyRequests }
        if status == 400 || status == 403 || status == 422 {
            let validation = object?["detail"] as? [[String: Any]]
            let message = detail?["message"] as? String ?? object?["detail"] as? String
                ?? validation?.compactMap { $0["msg"] as? String }.joined(separator: "; ")
                ?? "Invalid text or voice"
            return .badRequest(message)
        }
        return .http(status)
    }

    nonisolated private struct VoiceList: Decodable {
        var voices: [ElevenLabsVoice]
    }

    nonisolated private struct AddedVoice: Decodable {
        var voice_id: String
    }

    nonisolated private struct SpeechRequest: Encodable {
        var text: String
        var model_id: String
        var voice_settings: VoiceSettings

        nonisolated struct VoiceSettings: Encodable {
            var stability: Double
            var similarity_boost: Double
            var use_speaker_boost = true
        }
    }
}
