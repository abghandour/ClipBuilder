import SwiftUI

/// Developer terminology is confined to this collapsed form and its help sheet.
struct GoogleDriveAdvancedSettings: View {
    @Environment(AppStore.self) private var store
    @State private var expanded = false
    @State private var model = GoogleDriveAdvancedSettingsModel()
    @State private var help = false

    var body: some View {
        @Bindable var model = model
        DisclosureGroup("Advanced", isExpanded: $expanded) {
            Text("Use your own Google credentials on this Mac. They are stored securely in Keychain.")
                .font(.caption)
            Text(model.source.description)
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Client ID").font(.caption)
                TextField("Client ID", text: $model.clientID, prompt: Text("Paste your Client ID"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Text("Client Secret").font(.caption)
                SecureField("Client Secret", text: $model.clientSecret, prompt: Text("Paste your Client Secret"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.saving)
            HStack {
                Button("Save") { save(clear: false) }
                    .disabled(!model.canSave)
                Button("Use App Defaults") { save(clear: true) }.disabled(model.saving)
                Button("Where do I get these?") { help = true }
            }
            if let message = model.message { Text(message).font(.caption) }
        }
        .task { await model.load(auth: store.googleDrive.auth) }
        .sheet(isPresented: $help) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Use your own Google credentials").font(.headline)
                Text(
                    "In Google Cloud Console, enable the Google Drive API, configure the consent screen, and add your Google account as a test user. Create an OAuth client of type Desktop app. Copy its Client ID and Client Secret into this Advanced form."
                )
                Link(
                    "Open Google Cloud Console",
                    destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                Text("This is optional. A normal copy of Clip Builder already includes what you need to connect.")
                Button("Done") { help = false }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 480)
        }
    }

    private func save(clear: Bool) {
        Task {
            await model.save(clear: clear, drive: store.googleDrive, activeProfile: store.activeProfile.profileName)
        }
    }
}
