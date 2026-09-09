import SwiftUI

struct AssetSyncSettingsSection: View {
    @Environment(AppStore.self) private var store
    @State private var choosingFolder = false
    @State private var error: String?
    private var profile: String { store.activeProfile.profileName }

    static func isVisible(connection: DriveConnectionState?) -> Bool { connection?.isConnected == true }

    var body: some View {
        Section("Asset library") {
            if let home = store.googleDrive.assetHomes[profile] {
                LabeledContent("Folder", value: home.selection.breadcrumb)
                HStack {
                    Button("Change…") { choosingFolder = true }
                    Button("Forget folder") {
                        Task {
                            do { try await store.googleDrive.forgetAssetHome(profile: profile) } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                }.disabled(home.isRefreshing)
                AssetSyncRefreshButton(home: home, showsStatus: true)
                Text(
                    "The local library is shared across profiles. Each profile adds to the same library, even when its Drive folder is different."
                )
                .font(.caption).foregroundStyle(.secondary)
                if store.googleDrive.jobs.contains(where: {
                    $0.profile == profile && $0.isAsset && $0.status != .complete
                }) {
                    DisclosureGroup("Refresh details") { DriveActivityRows(assetProfile: profile) }
                }
            } else {
                Text("Keep music, fonts, images, bumpers, overlays and screen crops in a Drive folder")
                Button("Choose folder…") { choosingFolder = true }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .sheet(isPresented: $choosingFolder) {
            let selectedProfile = profile
            GoogleDriveBrowserSheet(pickFolder: { folder, breadcrumb in
                try await store.googleDrive.chooseAssetHome(folder, breadcrumb: breadcrumb, profile: selectedProfile)
            })
        }
        .onChange(of: profile) {
            choosingFolder = false
            error = nil
        }
    }
}
