import SwiftUI

struct DriveSourceProgress: View {
    @Environment(AppStore.self) private var store
    let media: DriveMedia

    var body: some View {
        if let job = store.googleDrive.uploadJob(for: media, profile: store.activeProfile.profileName) {
            HStack(spacing: 4) {
                if store.googleDrive.states[job.profile]?.isConnected != true {
                    OpenGoogleDriveSettingsButton()
                } else if job.status == .running {
                    ProgressView(value: job.progress).frame(width: 40)
                        .help("Uploading: \(Int(job.progress * 100))%")
                        .accessibilityLabel("Upload progress")
                } else {
                    Text(job.status == .waiting ? "Waiting" : job.message)
                        .lineLimit(1).help(job.message)
                    if job.status == .failed || job.status == .stopped || job.status == .reconnect {
                        Button("Resume") { store.googleDrive.resume(job.id) }
                        if job.status == .reconnect {
                            OpenGoogleDriveSettingsButton()
                        }
                    }
                }
            }.font(.caption)
        }
    }
}
