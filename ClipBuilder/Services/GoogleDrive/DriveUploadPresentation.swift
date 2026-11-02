import Foundation

/// How a source's pending Drive upload is shown: a cloud glyph in the
/// Sources row, and the state's words plus its actions in the footer under
/// the selection, so the row never has to fit buttons.
nonisolated enum DriveUploadPresentation {
    enum Action: Sendable, Equatable {
        /// Resume the same job: the file is where the job expects it.
        case resume
        /// The file left the job's path (renamed or moved): start the
        /// upload again from the file's current path.
        case uploadAgain
    }

    struct State: Sendable, Equatable {
        /// SF Symbol for the row.
        var symbol: String
        /// The row glyph is tinted as a warning when the upload needs the user.
        var needsAttention: Bool
        /// Tooltip and accessibility label of the glyph.
        var glyphLabel: String
        /// The footer's sentence.
        var text: String
        var primary: Action?
        var primaryTitle: String? {
            switch primary {
            case .resume: "Resume upload"
            case .uploadAgain: "Upload again"
            case nil: nil
            }
        }
        var cancelTitle: String { "Cancel upload" }
        var cancelHelp: String { "Forget this upload; the file stays on this Mac" }
    }

    /// The row and footer words when Google Drive is not connected on
    /// this Mac, whatever the job's own state.
    static let disconnectedLabel = "Upload paused — Google Drive is not connected on this Mac"
    static let disconnectedText = "Upload paused: Google Drive is not connected on this Mac. Connect it in Settings to continue."

    /// `fileExists`: whether the job's local path still holds the file.
    static func state(status: DriveTransfer.Status, message: String, progress: Double,
                      fileExists: Bool) -> State? {
        switch status {
        case .complete:
            return nil
        case .running:
            return State(symbol: "icloud.and.arrow.up", needsAttention: false,
                         glyphLabel: "Uploading to Google Drive, \(Int(progress * 100))%",
                         text: "Uploading to Google Drive — \(Int(progress * 100))%", primary: nil)
        case .waiting:
            return State(symbol: "icloud.and.arrow.up", needsAttention: false,
                         glyphLabel: "Waiting to upload to Google Drive",
                         text: "Waiting to upload to Google Drive behind the uploads already running", primary: nil)
        case .reconnect:
            return State(symbol: "exclamationmark.icloud", needsAttention: true,
                         glyphLabel: "Upload paused — sign in to Google Drive again",
                         text: "Upload paused: sign in to Google Drive again, then resume", primary: .resume)
        case .stopped, .failed:
            if !fileExists {
                return State(symbol: "exclamationmark.icloud", needsAttention: true,
                             glyphLabel: "Upload failed — the file was renamed or moved",
                             text: "Upload failed: the file was renamed or moved after the upload started. Upload it again from its current name.",
                             primary: .uploadAgain)
            }
            let detail = message.isEmpty ? "" : " — " + message
            return State(symbol: "exclamationmark.icloud", needsAttention: true,
                         glyphLabel: status == .stopped ? "Upload stopped — resume to continue" : "Upload failed — resume to retry",
                         text: (status == .stopped ? "Upload stopped" : "Upload failed") + detail, primary: .resume)
        }
    }
}
