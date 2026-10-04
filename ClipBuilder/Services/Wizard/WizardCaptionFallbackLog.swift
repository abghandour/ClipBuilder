import Foundation

/// One assembly owns this ledger, shared safely by its concurrent extractions.
actor WizardCaptionFallbackLog {
    private var logged: Set<String> = []

    func shouldLog(videoID: Int64, language: String) -> Bool {
        logged.insert("\(videoID):\(language)").inserted
    }
}
