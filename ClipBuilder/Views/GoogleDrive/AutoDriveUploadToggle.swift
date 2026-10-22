import SwiftUI

/// Both settings tabs edit the same profile-local Drive preference.
struct AutoDriveUploadToggle: View {
    @Environment(AppStore.self) private var store
    @State private var enabled = true
    @State private var loadedGeneration: Int?
    @State private var saving = false

    var body: some View {
        Toggle("Upload new sources to Google Drive automatically", isOn: selection)
            .disabled(loadedGeneration != store.profileGeneration || saving)
            .help("When this profile is attached to a team, upload newly added local videos in the background.")
            .task(id: store.profileGeneration) {
                loadedGeneration = nil
                let generation = store.profileGeneration
                guard let database = store.database else { return }
                do {
                    let value = try await database.autoUploadNewSourcesEnabled()
                    guard generation == store.profileGeneration, !Task.isCancelled else { return }
                    enabled = value
                    loadedGeneration = generation
                } catch {
                    store.presentError("Could not load automatic upload setting", error)
                }
            }
    }

    private var selection: Binding<Bool> {
        Binding(get: { enabled }, set: { value in
            guard let database = store.database, loadedGeneration == store.profileGeneration else { return }
            let generation = store.profileGeneration
            let previous = enabled
            enabled = value
            saving = true
            Task {
                defer { saving = false }
                do { try await database.setAutoUploadNewSourcesEnabled(value) }
                catch {
                    if generation == store.profileGeneration { enabled = previous }
                    store.presentError("Could not save automatic upload setting", error)
                }
            }
        })
    }
}
