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
        }
        .frame(width: 560, height: 520)
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
