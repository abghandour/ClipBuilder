import Foundation

/// Multipart framing stays independent of networking and actor isolation.
nonisolated struct ElevenLabsMultipart: Sendable {
    let body: Data
    let contentType: String

    static func voice(name: String, files: [URL], labels: [String: String],
                      removeBackgroundNoise: Bool) throws -> Self {
        guard !files.isEmpty else { throw ElevenLabsError.badRequest("Add a voice sample") }
        let boundary = "ClipBuilder-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("name", name)
        field("remove_background_noise", removeBackgroundNoise ? "true" : "false")
        field("description", "Cloned from analyzed footage in Clip Builder with the speaker's permission.")
        field("labels", String(decoding: try JSONEncoder().encode(labels), as: UTF8.self))
        for file in files {
            try Task.checkCancellation()
            // A leaf name is metadata, never multipart syntax.
            let filename = file.lastPathComponent.replacingOccurrences(of: "\r", with: "_")
                .replacingOccurrences(of: "\n", with: "_").replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\n")
            let type = file.pathExtension.lowercased() == "mp3" ? "audio/mpeg" : "application/octet-stream"
            append("Content-Type: \(type)\r\n\r\n")
            body.append(try Data(contentsOf: file))
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return Self(body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }

    /// One audio file for Scribe. Word timestamps and speaker turns are
    /// always asked for; sound tags never.
    static func speechToText(file: URL, model: String, language: String?, keyterms: [String]) throws -> Self {
        let boundary = "ClipBuilder-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model_id", model)
        if let language, !language.isEmpty { field("language_code", language) }
        field("diarize", "true")
        field("timestamps_granularity", "word")
        field("tag_audio_events", "false")
        // A hint is one line of text, never multipart syntax.
        for term in keyterms { field("keyterms", term.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")) }
        let type = ["m4a": "audio/mp4", "mp3": "audio/mpeg", "wav": "audio/wav"][file.pathExtension.lowercased()] ?? "application/octet-stream"
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(file.pathExtension.lowercased())\"\r\n")
        append("Content-Type: \(type)\r\n\r\n")
        try Task.checkCancellation()
        body.append(try Data(contentsOf: file, options: .mappedIfSafe))
        append("\r\n--\(boundary)--\r\n")
        return Self(body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }
}
