import SwiftUI

struct GoogleDriveSettingsView: View {
    @Environment(AppStore.self) private var store
    private var drive: GoogleDriveTransfers { store.googleDrive }
    private var profile: String { store.activeProfile.profileName }

    var body: some View {
        Form {
            Section("Google Drive") {
                switch drive.states[profile] ?? .notConfigured {
                case .notConfigured:
                    Text("Google Drive isn't available in this copy of Clip Builder.")
                case .disconnected:
                    Text("Connect Google Drive for \(profile).")
                    connectButton("Connect")
                case .connected(let email, let expires):
                    LabeledContent("Connected account", value: email)
                    Text("Expires \(expires.formatted(date: .abbreviated, time: .shortened))")
                    connectButton("Reconnect")
                    Button("Disconnect") { drive.disconnect(profile: profile) }
                case .reconnect(let email, let expires):
                    LabeledContent("Account", value: email)
                    Label(
                        "Google asked us to sign in again.",
                        systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                    if let expires {
                        Text("Connection expired \(expires.formatted(date: .abbreviated, time: .shortened))")
                    }
                    connectButton("Reconnect")
                    Button("Disconnect") { drive.disconnect(profile: profile) }
                }
                if let error = drive.connectionError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section { GoogleDriveAdvancedSettings() }
            Section {
                Text(
                    "Google may ask you to sign in again after seven days. Use the same account to continue your transfers. Your connection is saved securely on this Mac."
                )
                Text("Only media files are uploaded. Projects, timelines, analysis and settings stay on this Mac.")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task(id: profile) {
            if let database = store.database { await drive.attach(profile: store.activeProfile, database: database) }
            await drive.refreshState(profile: profile)
        }
    }
    private func connectButton(_ title: String) -> some View {
        Button(drive.connecting.contains(profile) ? "Connecting…" : title) { drive.connect(profile: profile) }
            .disabled(drive.connecting.contains(profile))
    }
}
