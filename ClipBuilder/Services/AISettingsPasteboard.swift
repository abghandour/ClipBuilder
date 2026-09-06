import AppKit

@MainActor enum AISettingsPasteboard {
    static let type = NSPasteboard.PasteboardType("com.mokotti-solutions.clipbuilder.ai-settings")
    static func write(_ envelope: AISettingsEnvelope, to board: NSPasteboard = .general) {
        guard let text = AISettingsJSON.encode(envelope) else { return }
        board.clearContents()
        board.setData(Data(text.utf8), forType: type)
        board.setString(text, forType: .string)
    }
    /// Copying an informational value must not discard reusable settings.
    static func writeText(_ text: String, to board: NSPasteboard = .general) {
        let envelope = board.data(forType: type)
        board.clearContents()
        if let envelope { board.setData(envelope, forType: type) }
        board.setString(text, forType: .string)
    }

    static func read(from board: NSPasteboard = .general) -> AISettingsEnvelope? {
        guard let data = board.data(forType: type), data.count < 8_000_000,
            let value = try? JSONDecoder().decode(AISettingsEnvelope.self, from: data),
            value.version == 1
        else { return nil }
        return value
    }
}
