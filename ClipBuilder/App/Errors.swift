import Foundation

/// One alert-worthy problem. Queued in AppStore so a second failure doesn't
/// silently replace the first while its alert is still up.
nonisolated struct AppError: Identifiable, Equatable, Sendable {
    let id = UUID()
    var message: String
    var context: String = "Error"
    var details: String = ""
    /// Set when the failure was a CLI sign-in problem: the alert offers a
    /// Sign In button that opens this provider's login in Terminal.
    var signInProvider: String? = nil

    /// The alert for a failed operation. Details carry the reflected error
    /// for bug reports, but not when it would only repeat the message.
    static func failure(context: String, error: Error) -> AppError {
        let message = error.userMessage
        let reflected = String(reflecting: error)
        let details = reflected == message ? message : "\(message)\n\(reflected)"
        var appError = AppError(message: "\(context): \(message)", context: context, details: details)
        if case .notAuthenticated(let provider, _)? = error as? AIError {
            appError.signInProvider = provider
        }
        return appError
    }
}

/// One line of the app's unified log, shown in the status bar's drawer.
nonisolated struct AppLogLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: Date
    let channel: String
    let text: String
}

nonisolated extension Error {
    /// A message fit for an alert: our own error types describe themselves;
    /// Foundation/system errors use their localized description instead of
    /// the raw "Error Domain=… Code=…" dump that string interpolation gives.
    var userMessage: String {
        if let localized = (self as? LocalizedError)?.errorDescription {
            return localized
        }
        return localizedDescription
    }
}

// The app's error enums already produce user-quality text via
// CustomStringConvertible; routing that through LocalizedError makes
// `userMessage` (and localizedDescription) pick it up.

nonisolated extension SQLiteError: LocalizedError {
    var errorDescription: String? { description }
}

nonisolated extension FFmpegError: LocalizedError {
    var errorDescription: String? { description }
}

nonisolated extension PreviewError: LocalizedError {
    var errorDescription: String? { description }
}

nonisolated extension ProcessRunnerError: LocalizedError {
    var errorDescription: String? { description }
}

nonisolated extension AIError: LocalizedError {
    var errorDescription: String? { description }
}

nonisolated extension TranscriptionError: LocalizedError {
    var errorDescription: String? { description }
}

nonisolated extension InstagramError: LocalizedError {
    var errorDescription: String? { description }
}

nonisolated extension UpdateError: LocalizedError {
    var errorDescription: String? { description }
}
