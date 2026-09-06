import SwiftUI

struct OpenGoogleDriveSettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settings.selectedTab") private var selectedTab = "profile"
    var beforeOpening: () -> Void = {}

    var body: some View {
        Button("Open Google Drive Settings") {
            selectedTab = "googleDrive"
            beforeOpening()
            openSettings()
        }
    }
}

struct GoogleDriveConnectionPrompt: View {
    @Environment(AppStore.self) private var store
    let profile: String
    var allowsInlineConnect = false
    var beforeOpeningSettings: () -> Void = {}
    @AppStorage("googleDrive.hasSeenIntroduction") private var hasSeenIntroduction = false
    @State private var introducing = false

    private var state: DriveConnectionState { store.googleDrive.states[profile] ?? .notConfigured }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Google Drive", systemImage: "cloud").font(.headline)
            if state == .notConfigured {
                Text("Google Drive isn't available in this copy of Clip Builder.")
            } else if introducing {
                Text("Connect to browse and download your Drive videos, and upload source videos or finished reels.")
                Text("Your projects, timelines, analysis and settings stay on this Mac.")
                Button(store.googleDrive.connecting.contains(profile) ? "Connecting…" : "Connect") {
                    store.googleDrive.connect(profile: profile)
                }
                .disabled(store.googleDrive.connecting.contains(profile))
            } else {
                Text("Sign in to Google to browse your videos and continue transfers.")
            }
            OpenGoogleDriveSettingsButton(beforeOpening: beforeOpeningSettings)
            if let error = store.googleDrive.connectionError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            if allowsInlineConnect && !hasSeenIntroduction && state != .notConfigured {
                introducing = true
                hasSeenIntroduction = true
            }
        }
        .onChange(of: state) {
            if allowsInlineConnect && !hasSeenIntroduction && state != .notConfigured {
                introducing = true
                hasSeenIntroduction = true
            }
        }
    }
}

extension DriveConnectionState {
    nonisolated var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
