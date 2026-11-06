import BugReporterKit
import Foundation
import Synchronization

/// Errors that a view shows inline (a caption, a sheet row) instead of
/// through `AppStore.presentError` still belong in the console's Errors
/// channel. The store installs the sink at launch; before that, and in
/// tests without a store, lines only go to the diagnostic file.
nonisolated enum ErrorLog {
    private static let sink = Mutex<(@Sendable (String) -> Void)?>(nil)

    static func install(_ handler: @escaping @Sendable (String) -> Void) {
        sink.withLock { $0 = handler }
    }

    /// One line, prefixed with where it happened.
    static func record(_ context: String, _ message: String) {
        let line = context.isEmpty ? message : "\(context): \(message)"
        if let handler = sink.withLock({ $0 }) {
            handler(line)
        } else {
            BugReporter.log("error", line)
        }
    }

    /// "Views/SettingsView.swift" → "SettingsView".
    static func context(fileID: String) -> String {
        let name = fileID.split(separator: "/").last.map(String.init) ?? fileID
        return name.hasSuffix(".swift") ? String(name.dropLast(6)) : name
    }
}

extension Error {
    /// The message to show the user, also written to the Errors console
    /// channel. Cancellations are not errors and are not logged.
    nonisolated func logged(_ context: String = "", fileID: String = #fileID) -> String {
        let message = localizedDescription
        if !(self is CancellationError) {
            ErrorLog.record(context.isEmpty ? ErrorLog.context(fileID: fileID) : context, message)
        }
        return message
    }
}
