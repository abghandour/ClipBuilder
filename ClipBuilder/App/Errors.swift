import Foundation

/// One alert-worthy problem. Queued in AppStore so a second failure doesn't
/// silently replace the first while its alert is still up.
nonisolated struct AppError: Identifiable, Equatable, Sendable {
    let id = UUID()
    var message: String
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
