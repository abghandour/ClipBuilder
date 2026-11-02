import SwiftUI

/// The cloud glyph beside a source whose Drive upload is pending: progress
/// while it runs, a warning cloud when it needs the user. The words and
/// the Resume / Upload again / Cancel buttons live in the Sources footer
/// (`DriveUploadFooter`), where there is room for them.
struct DriveSourceProgress: View {
    @Environment(AppStore.self) private var store
    let media: DriveMedia

    var body: some View {
        if let job = store.googleDrive.uploadJob(for: media, profile: store.activeProfile.profileName) {
            if store.googleDrive.states[job.profile]?.isConnected != true {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                    .help(DriveUploadPresentation.disconnectedLabel)
                    .accessibilityLabel(DriveUploadPresentation.disconnectedLabel)
            } else if job.status == .running {
                ProgressView(value: job.progress).frame(width: 40)
                    .help("Uploading to Google Drive: \(Int(job.progress * 100))%")
                    .accessibilityLabel("Upload progress")
            } else if let state = DriveUploadPresentation.state(job) {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.needsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .help(state.glyphLabel)
                    .accessibilityLabel(state.glyphLabel)
            }
        }
    }
}

/// The selected source's pending upload, in words, with its actions.
struct DriveUploadFooter: View {
    @Environment(AppStore.self) private var store
    let video: VideoRecord

    var body: some View {
        let media = video.driveMedia
        if let job = store.googleDrive.uploadJob(for: media, profile: store.activeProfile.profileName),
           store.googleDrive.states[job.profile]?.isConnected != true {
            HStack(spacing: Theme.spaceXS) {
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange).accessibilityHidden(true)
                Text(DriveUploadPresentation.disconnectedText).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail).help(DriveUploadPresentation.disconnectedText)
                OpenGoogleDriveSettingsButton().lineLimit(1).fixedSize()
                Button("Cancel upload") { store.googleDrive.cancel(job.id) }
                    .lineLimit(1).fixedSize()
                    .help("Forget this upload; the file stays on this Mac")
            }
        } else if let job = store.googleDrive.uploadJob(for: media, profile: store.activeProfile.profileName),
           let state = DriveUploadPresentation.state(job) {
            HStack(spacing: Theme.spaceXS) {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.needsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                Text(state.text).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail).help(state.text)
                if let title = state.primaryTitle, let primary = state.primary {
                    Button(title) {
                        switch primary {
                        case .resume: store.googleDrive.resume(job.id)
                        case .uploadAgain: store.googleDrive.uploadAgain(job.id, media: media)
                        }
                    }
                    .lineLimit(1).fixedSize()
                    .help(primary == .resume ? "Continue this upload where it stopped"
                          : "Start the upload again from the file's current name and location")
                }
                Button(state.cancelTitle) { store.googleDrive.cancel(job.id) }
                    .lineLimit(1).fixedSize()
                    .help(state.cancelHelp)
            }
        }
    }
}

extension DriveUploadPresentation {
    static func state(_ job: DriveTransfer) -> State? {
        state(status: job.status, message: job.message, progress: job.progress,
              fileExists: job.media.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
    }
}
