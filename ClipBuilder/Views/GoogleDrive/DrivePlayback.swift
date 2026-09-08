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
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Report…")
            let response: NSApplication.ModalResponse
            if let window = NSApp.keyWindow {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            if response == .alertSecondButtonReturn {
                BugReporting.presentReport(title: alert.messageText, details: alert.informativeText)
            }
            return false
        }
    }
}
