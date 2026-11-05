import SwiftUI

/// The beta's mark in every window's toolbar: a blue capsule reading BETA.
/// Clicking it says what the beta is and where the stable app lives. The
/// stable app has no mark at all; absence is the stable signal.
struct BetaBadge: View {
    @State private var showsInfo = false

    var body: some View {
        Button {
            showsInfo.toggle()
        } label: {
            Text("BETA")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.projectTint, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Clip Builder Beta \(AppStore.versionAndBuild)")
        .accessibilityLabel("Beta channel")
        .popover(isPresented: $showsInfo, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                Text("Clip Builder Beta \(AppStore.versionAndBuild)").font(.headline)
                Text("Updates to every release, including ones not yet marked stable. "
                     + "Its library and settings are its own copies; the stable app's are untouched.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Download the Stable App…") {
                    NSWorkspace.shared.open(UpdateService.releasesPage)
                }
            }
            .padding(Theme.spaceM)
            .frame(width: 320)
        }
    }
}

/// Settings › General, beta only: the library commands between the two apps.
struct ChannelSettingsSection: View {
    @Environment(AppStore.self) private var store
    @State private var confirmReplace = false
    @State private var confirmPromote = false

    var body: some View {
        Section {
            LabeledContent("This app") {
                Text("Clip Builder Beta \(AppStore.versionAndBuild)").foregroundStyle(.secondary)
            }
            LabeledContent("Library") {
                Text(SettingsStore.databaseURL(profileName: store.activeProfile.profileName).lastPathComponent)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Replace with the Stable Library…") { confirmReplace = true }
                Button("Copy to the Stable App…") { confirmPromote = true }
            }
            Text("Replace starts \(store.activeProfile.profileName) over from the stable app's library. "
                 + "Copy makes the stable app use this beta library (quit Clip Builder first); "
                 + "its previous library goes to data/db-backups.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Channel")
        } footer: {
            Text("The beta updates to every release; the stable app only to blessed ones.").lineLimit(1)
        }
        .confirmationDialog("Replace the \(store.activeProfile.profileName) beta library?",
                            isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { store.replaceLibraryWithStable() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything this profile did in the beta since the last import is lost. Synced data comes back through the team.")
        }
        .confirmationDialog("Copy the \(store.activeProfile.profileName) beta library to Clip Builder?",
                            isPresented: $confirmPromote, titleVisibility: .visible) {
            Button("Copy", role: .destructive) { store.promoteLibraryToStable() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clip Builder's current library for this profile is backed up to data/db-backups first.")
        }
    }
}
