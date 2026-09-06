import AppKit

@MainActor
enum DrivePlayback {
    /// Errors are visible even in previews whose media frameworks only report
    /// an empty player. Reconnect itself is offered by the Activity row.
    static func prepare(_ url: URL) async -> Bool {
        do {
            try await DriveMediaResolver.shared.ensureLocal(url)
            try Task.checkCancellation()
            return true
        } catch is CancellationError { return false } catch {
            let alert = NSAlert()
            alert.messageText = "Could not open media"
            alert.informativeText = error.localizedDescription
            if let window = NSApp.keyWindow { _ = await alert.beginSheetModal(for: window) }
            return false
        }
    }
}
