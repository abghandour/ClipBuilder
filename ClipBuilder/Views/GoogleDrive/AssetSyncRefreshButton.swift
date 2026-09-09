import SwiftUI

struct AssetSyncRefreshButton: View {
    @Environment(AppStore.self) private var store
    let home: AssetSyncHome
    var showsStatus = false

    static func canRefresh(home: AssetSyncHome, connection: DriveConnectionState?) -> Bool {
        home.canRefresh && connection?.isConnected == true
    }

    var body: some View {
        HStack {
            Button("Refresh", systemImage: "arrow.clockwise.icloud") {
                let profile = store.activeProfile.profileName
                store.googleDrive.refreshAssets(profile: profile) { line in
                    store.appendLog(\.pipelineLog, ["Asset library · \(profile): \(line)"])
                }
            }
            .disabled(
                !Self.canRefresh(home: home, connection: store.googleDrive.states[store.activeProfile.profileName])
                    || store.googleDrive.assetHomes.values.contains(where: { $0.isRefreshing })
            )
            .help(home.rowStatus)
            Text(home.rowStatus).font(.caption).foregroundStyle(.secondary)
                .lineLimit(showsStatus ? nil : 1)
                .help(home.rowStatus)
            if home.isRefreshing { Button("Stop") { home.stop() } }
        }
    }
}
