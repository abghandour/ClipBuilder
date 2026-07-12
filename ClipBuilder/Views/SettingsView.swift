import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ProfileSettingsTab()
                .tabItem { Label("Profile", systemImage: "person.crop.square") }
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
            InstagramSettingsTab()
                .tabItem { Label("Instagram", systemImage: "play.rectangle.on.rectangle") }
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: - Instagram

private struct InstagramSettingsTab: View {
    @Environment(AppStore.self) private var store
    @State private var testResult: String?
    @State private var testing = false
    @State private var graphToken = ""

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Own Account (Graph API)") {
                if store.settings.instagram.isGraphConnected {
                    LabeledContent("Connected") {
                        Label("@\(store.settings.instagram.connectedUsername)",
                              systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                    Button("Disconnect") { store.disconnectInstagram() }
                    Text("Reels for this account fetch through the official API with full insights (reach, saves, shares, watch time). If the token expires, fetches fall back to the public web API — reconnect here with a fresh token.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    SecureField("Access token", text: $graphToken,
                                prompt: Text("Long-lived Meta access token"))
                    Button(store.isConnectingInstagram ? "Connecting…" : "Connect") {
                        store.connectInstagram(token: graphToken)
                        graphToken = ""
                    }
                    .disabled(graphToken.trimmingCharacters(in: .whitespaces).isEmpty
                              || store.isConnectingInstagram)
                    Text("Paste a long-lived access token from a Meta app with instagram_basic and instagram_manage_insights, for the Facebook page linked to your business/creator account. Stored in the Keychain, never in settings files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Fetching") {
                Picker("Browser cookies", selection: $store.settings.instagram.cookieSource) {
                    Text("None (anonymous)").tag("none")
                    Text("Safari").tag("safari")
                    Text("Chrome").tag("chrome")
                    Text("Firefox").tag("firefox")
                    Text("cookies.txt file").tag("file")
                }
                if store.settings.instagram.cookieSource == "file" {
                    TextField("Cookies file path", text: $store.settings.instagram.cookieFilePath,
                              prompt: Text("~/Downloads/instagram-cookies.txt"))
                }
                Stepper("Reels per fetch: \(store.settings.instagram.fetchLimit)",
                        value: $store.settings.instagram.fetchLimit, in: 4...24, step: 4)
                Text("Listing uses Instagram's public web API — anonymous works for public accounts; a cookies.txt makes it reliable. Browser-cookie options apply to video downloads (via yt-dlp) only. Note this accesses Instagram outside its official API — fetches are kept small on purpose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Test") {
                HStack {
                    Button(testing ? "Testing…" : "Test Fetch") {
                        runTestFetch()
                    }
                    .disabled(testing)
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.hasPrefix("OK") ? .green : .red)
                            .lineLimit(2)
                    }
                }
            }

            Section {
                Button("Save") {
                    store.saveSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
    }

    private func runTestFetch() {
        testing = true
        testResult = nil
        let settings = store.settings.instagram
        let handle = store.activeProfile.socials["instagram"]?.handle
            .trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) ?? ""
        let username = handle.isEmpty ? "instagram" : handle
        Task {
            do {
                let provider = InstagramWebProvider(settings: settings)
                let profile = try await provider.fetchProfile(username: username) { _ in }
                testResult = "OK — reached @\(profile.username)"
            } catch {
                testResult = "\(error)"
            }
            testing = false
        }
    }
}

// MARK: - Profile

private struct ProfileSettingsTab: View {
    @Environment(AppStore.self) private var store
    @State private var newProfileName = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Profile") {
                Picker("Active profile", selection: Binding(
                    get: { store.activeProfile.profileName },
                    set: { store.switchProfile(named: $0) }
                )) {
                    ForEach(store.profiles) { profile in
                        Text(profile.profileName).tag(profile.profileName)
                    }
                }
                HStack {
                    TextField("New profile name", text: $newProfileName)
                    Button("Create") {
                        store.createProfile(named: newProfileName)
                        newProfileName = ""
                    }
                    .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Delete This Profile…", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .disabled(store.activeProfile.profileName == "Default")
            }

            Section("Brand") {
                TextField("Brand name", text: $store.activeProfile.brandName)
                TextField("Content domain", text: $store.activeProfile.contentDomain,
                          prompt: Text("MMA, cooking, travel…"))
                TextField("Instagram handle", text: Binding(
                    get: { store.activeProfile.socials["instagram"]?.handle ?? "" },
                    set: { store.activeProfile.socials["instagram", default: SocialSlot()].handle = $0 }
                ))
            }

            Section("Folders") {
                folderRow(title: "Input folder", path: $store.activeProfile.sourceFolder)
                folderRow(title: "Output folder", path: $store.activeProfile.outputFolder)
            }

            Section("Intro / Outro") {
                fileRow(title: "Intro video", path: Binding(
                    get: { store.activeProfile.introVideo ?? "" },
                    set: { store.activeProfile.introVideo = $0.isEmpty ? nil : $0 }))
                fileRow(title: "Outro video", path: Binding(
                    get: { store.activeProfile.outroVideo ?? "" },
                    set: { store.activeProfile.outroVideo = $0.isEmpty ? nil : $0 }))
            }

            Section("Tag Schema") {
                Text("One category per row; comma-separated tags. Leave empty to use the built-in schema.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(store.activeProfile.tagSchema.keys.sorted(), id: \.self) { category in
                    HStack {
                        Text(category)
                            .frame(width: 80, alignment: .leading)
                        TextField("tags", text: Binding(
                            get: { store.activeProfile.tagSchema[category]?.joined(separator: ", ") ?? "" },
                            set: { store.activeProfile.tagSchema[category] = $0
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty } }
                        ))
                        Button {
                            store.activeProfile.tagSchema.removeValue(forKey: category)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Category") {
                    var index = 1
                    while store.activeProfile.tagSchema["category\(index)"] != nil { index += 1 }
                    store.activeProfile.tagSchema["category\(index)"] = []
                }
            }

            Section {
                Button("Save Profile") {
                    store.saveActiveProfile()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete profile \"\(store.activeProfile.profileName)\"?",
                            isPresented: $showDeleteConfirmation) {
            Button("Delete Profile and Its Database", role: .destructive) {
                store.deleteProfile(named: store.activeProfile.profileName)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the profile configuration and its scene database. Source and output video files are not touched.")
        }
    }

    private func folderRow(title: String, path: Binding<String>) -> some View {
        HStack {
            TextField(title, text: path)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url {
                    path.wrappedValue = url.path
                }
            }
        }
    }

    private func fileRow(title: String, path: Binding<String>) -> some View {
        HStack {
            TextField(title, text: path, prompt: Text("None"))
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                if panel.runModal() == .OK, let url = panel.url {
                    path.wrappedValue = url.path
                }
            }
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(AppStore.self) private var store
    @AppStorage(SettingsStore.dataFolderDefaultsKey) private var dataFolder = ""
    // Resolved off-main once: when ffmpeg is missing, the lookup falls back
    // to a blocking login-shell spawn, which must not run per body pass
    // (this tab re-renders on every keystroke in its text fields).
    @State private var ffmpegAvailable: Bool?

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Analysis") {
                Picker("Analysis mode", selection: $store.settings.analysisMode) {
                    Text("Visual (frame sampling)").tag("visual")
                    Text("Speech-first (transcript scenes)").tag("speech")
                }
                Text("Visual suits action footage; speech-first suits interviews and tutorials. Speech-first scene detection is not ported yet — transcription itself is available from the Analyze tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                LabeledContent("Engine", value: "Apple SpeechAnalyzer (on-device)")
                TextField("Language code", text: $store.settings.transcribeLanguage,
                          prompt: Text("Auto (current locale)"))
                TextField("Vocabulary hint", text: $store.settings.transcribeHint,
                          prompt: Text("Domain-specific names, code-switching notes…"))
            }

            Section("Storage") {
                HStack {
                    TextField("Data folder", text: $dataFolder,
                              prompt: Text(SettingsStore.dataDirectory.path))
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            dataFolder = url.path
                        }
                    }
                }
                Text("Databases and caches live here. Point this at a clip-builder checkout's data/ folder to share scene databases with the Python app, then relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("ffmpeg") {
                    switch ffmpegAvailable {
                    case .none:
                        Text("Checking…")
                            .foregroundStyle(.secondary)
                    case .some(true):
                        Text("Found")
                            .foregroundStyle(.green)
                    case .some(false):
                        Text("Not found — brew install ffmpeg")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                Button("Save") {
                    store.saveSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .task {
            ffmpegAvailable = await Task.detached { FFmpeg.isAvailable }.value
        }
    }
}

// MARK: - AI

private struct AISettingsTab: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Task Routing") {
                ForEach(AICatalog.tasks, id: \.self) { task in
                    Picker(AICatalog.taskLabels[task] ?? task, selection: Binding(
                        get: { store.settings.ai.tasks[task] ?? AICatalog.taskDefaults[task] ?? "claude" },
                        set: { store.settings.ai.tasks[task] = $0 }
                    )) {
                        ForEach(AICatalog.providers, id: \.key) { provider in
                            Text(provider.label).tag(provider.key)
                        }
                    }
                }
            }

            ForEach(AICatalog.providers, id: \.key) { provider in
                Section(provider.label) {
                    AvailabilityRow(providerKey: provider.key)
                    TextField("Binary path", text: Binding(
                        get: { store.settings.ai.providers[provider.key]?.bin ?? "" },
                        set: { store.settings.ai.providers[provider.key, default: AIProviderSettings()].bin =
                            $0.isEmpty ? nil : $0 }
                    ), prompt: Text(provider.bin))
                    Picker("Default model", selection: Binding(
                        get: { store.settings.ai.providers[provider.key]?.model ?? provider.defaultModel },
                        set: { store.settings.ai.providers[provider.key, default: AIProviderSettings()].model = $0 }
                    )) {
                        ForEach(provider.models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
            }

            Section {
                Button("Save") {
                    store.saveSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AvailabilityRow: View {
    @Environment(AppStore.self) private var store
    let providerKey: String
    @State private var available: Bool?

    var body: some View {
        LabeledContent("Status") {
            switch available {
            case .none:
                ProgressView().controlSize(.small)
            case .some(true):
                Text("Installed").foregroundStyle(.green)
            case .some(false):
                Text("Not found").foregroundStyle(.orange)
            }
        }
        .task(id: providerKey) {
            available = await store.ai.isProviderAvailable(providerKey)
        }
    }
}
