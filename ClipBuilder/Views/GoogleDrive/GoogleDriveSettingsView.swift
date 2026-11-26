import SwiftUI

struct GoogleDriveSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var confirmingDisconnect = false
    private var drive: GoogleDriveTransfers { store.googleDrive }
    private var profile: String { store.activeProfile.profileName }

    private var disconnectButton: some View {
        Button("Disconnect…") { confirmingDisconnect = true }
            .confirmationDialog("Disconnect Google Drive?", isPresented: $confirmingDisconnect) {
                Button("Disconnect", role: .destructive) { drive.disconnect(profile: profile) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Transfers stop and this profile forgets the account. Local files stay on this Mac.")
            }
    }

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
                    disconnectButton
                case .reconnect(let email, let expires):
                    LabeledContent("Account", value: email)
                    Label(
                        "Google asked us to sign in again.",
                        systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                    if let expires {
                        Text("Connection expired \(expires.formatted(date: .abbreviated, time: .shortened))")
                    }
                    connectButton("Reconnect")
                    disconnectButton
                }
                if let error = drive.connectionError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("This profile") {
                AutoDriveUploadToggle()
            }
            if AssetSyncSettingsSection.isVisible(connection: drive.states[profile]) {
                AssetSyncSettingsSection()
            }
            Section { GoogleDriveAdvancedSettings() }
            Section {
                Text(
                    "Google may ask you to sign in again after seven days. Use the same account to continue your transfers. Your connection is saved securely on this Mac."
                )
                if drive.assetHomes[profile] != nil {
                    Text(
                        "Media and library assets can be uploaded. Projects, timelines, analysis and settings stay on this Mac."
                    )
                } else {
                    Text("Only media files are uploaded. Projects, timelines, analysis and settings stay on this Mac.")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task(id: profile) {
            if let database = store.database { await drive.attach(profile: store.activeProfile, database: database) }
            await drive.refreshState(profile: profile)
        }
    }
    @ViewBuilder
    private func connectButton(_ title: String) -> some View {
        if drive.connecting.contains(profile) {
            GoogleDriveConnectingRow(profile: profile)
        } else {
            Button(title) { drive.connect(profile: profile) }
        }
    }
}

/// A sign-in waiting on the browser: where to look, and a way out.
struct GoogleDriveConnectingRow: View {
    @Environment(AppStore.self) private var store
    let profile: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Finish signing in to Google in your browser, and tick the Google Drive box.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel") { store.googleDrive.cancelConnect(profile: profile) }
                .lineLimit(1).fixedSize()
                .help("Stop waiting for the browser. Connect starts a new sign-in.")
        }
    }
}
