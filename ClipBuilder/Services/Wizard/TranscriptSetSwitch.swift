import Foundation

/// Pure rules for changing a video's transcript set from Express.
nonisolated enum TranscriptSetSwitch {
    /// The analysis batch to activate with transcript set `key`: the newest
    /// batch built from that set. Nil when the active batch already is one
    /// built from it, or when no batch was (the Q&A tab then offers to run
    /// the exchanges again).
    static func runKey(for key: String,
                       runs: [(id: Int64, runKey: String?, requestJSON: String?, settingsJSON: String?, createdAt: String?)],
                       activeRunID: Int64?) -> String? {
        // Only the key is read, so a request from another version still decodes.
        struct Request: Decodable { var transcriptKey: String? }
        // A batch that transcribed the video itself had no set to name in
        // its request; its settings record the one it made.
        struct Settings: Decodable { var transcriptionKey: String? }
        let built = runs.filter { run in
            if let named = AISettingsJSON.decode(Request.self, run.requestJSON)?.transcriptKey { return named == key }
            return AISettingsJSON.decode(Settings.self, run.settingsJSON)?.transcriptionKey == key
        }
        if built.contains(where: { $0.id == activeRunID }) { return nil }
        // Newest by creation time, then run key: a batch pulled from another
        // Mac gets a local row id that says nothing about its age.
        return built.filter { $0.runKey != nil }
            .max { ($0.createdAt ?? "", $0.runKey ?? "") < ($1.createdAt ?? "", $1.runKey ?? "") }?.runKey
    }

    /// The transcript set a history entry was made on, when it recorded one.
    /// Only that field is decoded: the menu asks for every entry.
    static func transcriptKey(of record: WizardHighlightRecord) -> String? {
        struct Settings: Decodable { var transcriptKey: String? }
        return AISettingsJSON.decode(Settings.self, record.settingsJSON)?.transcriptKey
    }

    /// The closed menu's label: enough to tell which transcript is in use.
    /// The model and length stay in the menu's own rows (`label`).
    static func shortLabel(_ set: TranscriptionSet) -> String {
        var parts = [(set.name?.isEmpty == false ? set.name : nil) ?? date(set.createdAt)]
        if set.editedCount > 0 { parts.append("\(set.editedCount) edited") }
        if set.isPinned { parts.append("pinned") }
        return parts.joined(separator: " · ")
    }

    /// A short menu label: when it was made, with what, and how long it is.
    static func label(_ set: TranscriptionSet) -> String {
        // A named set reads by its name; the date tells two of one name apart.
        if let name = set.name, !name.isEmpty { return "\(name) · \(date(set.createdAt))" }
        var parts = [date(set.createdAt), set.model ?? "Transcription", "\(set.segmentCount) segments"]
        if set.editedCount > 0 { parts.append("\(set.editedCount) edited") }
        if set.isPinned { parts.append("pinned") }
        return parts.joined(separator: " · ")
    }

    /// "2026-11-10T05:03:24.134" reads as "Nov 10, 05:03"; anything else is shown as stored.
    static func date(_ stored: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            parser.dateFormat = format
            if let date = parser.date(from: stored) {
                let output = DateFormatter()
                output.locale = Locale(identifier: "en_US_POSIX")
                // The clock time as stored, so it matches the Transcript sheet's list.
                output.timeZone = parser.timeZone
                output.dateFormat = "MMM d, HH:mm"
                return output.string(from: date)
            }
        }
        return stored
    }
}
