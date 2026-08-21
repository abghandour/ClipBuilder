import SwiftUI
import UniformTypeIdentifiers

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

            Section("Brand Kit") {
                HStack {
                    TextField("Logo image (watermark + outro)", text: $store.activeProfile.logoPath,
                              prompt: Text("path to a PNG with transparency"))
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        panel.allowedContentTypes = [.png, .jpeg, .image]
                        if panel.runModal() == .OK, let url = panel.url {
                            store.activeProfile.logoPath = url.path
                        }
                    }
                }
                TextField("Accent color", text: $store.activeProfile.accentColor,
                          prompt: Text("#E31B23 — used by headlines and cards"))
                TextField("Tagline", text: $store.activeProfile.tagline,
                          prompt: Text("shown under the logo on the outro card"))
                TextField("Caption languages", text: Binding(
                    get: { store.activeProfile.captionLanguages.joined(separator: ", ") },
                    set: { value in
                        store.activeProfile.captionLanguages = value
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                            .filter { !$0.isEmpty }
                    }), prompt: Text("en, pt — one caption block per language"))
                Text("The brand kit drives the wizard's watermark, result headline, and outro card — the pieces that make every reel look like the channel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Folders") {
                folderRow(title: "Input folder", path: $store.activeProfile.sourceFolder)
                folderRow(title: "Output folder", path: $store.activeProfile.outputFolder)
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

            Section("Taste") {
                Text("What a keeper moment looks like — distilled from sample reels you pick (Instagram → Add to Taste Profile, or study a local file below). Rides into every analysis (as the \"highlight\" tag) and every wizard plan. Edit freely; studying another sample refines rather than replaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $store.activeProfile.tasteRubric)
                    .font(.body)
                    .frame(minHeight: 90)
                if !store.activeProfile.tasteExemplarFrames.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.activeProfile.tasteExemplarFrames, id: \.self) { path in
                                if let image = NSImage(contentsOfFile: path) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(alignment: .topTrailing) {
                                            Button {
                                                store.removeTasteExemplarFrame(path: path)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, .black.opacity(0.6))
                                            }
                                            .buttonStyle(.plain)
                                            .padding(2)
                                            .help("Remove this example frame")
                                        }
                                }
                            }
                        }
                    }
                    Text("Example frames from your studied samples — attached to every analysis as visual definitions of the rubric (newest 8 kept).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack {
                    Button("Study Sample Video…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            store.studyTasteExemplar(url: url)
                        }
                    }
                    .disabled(store.isStudyingTaste)
                    if store.isStudyingTaste {
                        ProgressView()
                            .controlSize(.small)
                        Text("Studying…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !store.activeProfile.tasteCategories.isEmpty {
                    Text("Learned video types — each studied reel is classified into one of these and refines its rubric. The AI Wizard's Video type picker lists them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach($store.activeProfile.tasteCategories) { $category in
                        DisclosureGroup {
                            TextField("Label", text: $category.label)
                            TextEditor(text: $category.rubric)
                                .font(.body)
                                .frame(minHeight: 70)
                            HStack {
                                Text("\(category.exemplarFrames.count) example frame(s)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Button("Delete Type", role: .destructive) {
                                    store.removeTasteCategory(key: category.key)
                                }
                                .controlSize(.small)
                            }
                        } label: {
                            Text("\(category.label) · studied \(category.studiedCount) reel(s)")
                        }
                    }
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

}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(AppStore.self) private var store
    @AppStorage(SettingsStore.dataFolderDefaultsKey) private var dataFolder = ""
    // Resolved off-main once: when ffmpeg is missing, the lookup falls back
    // to a blocking login-shell spawn, which must not run per body pass
    // (this tab re-renders on every keystroke in its text fields).
    @State private var missingTools: [String]?

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
                ForEach(ToolInstaller.requiredTools, id: \.name) { tool in
                    LabeledContent(tool.name) {
                        switch (missingTools, store.isInstallingTools) {
                        case (_, true):
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Installing…")
                                    .foregroundStyle(.secondary)
                            }
                        case (.none, _):
                            Text("Checking…")
                                .foregroundStyle(.secondary)
                        case (.some(let missing), _) where !missing.contains(tool.name):
                            Text("Found")
                                .foregroundStyle(.green)
                        case (.some, _):
                            HStack {
                                Text("Not found")
                                    .foregroundStyle(.red)
                                Button("Install") {
                                    store.installMissingTools()
                                }
                            }
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
        .task {
            missingTools = await Task.detached { ToolInstaller.missingTools }.value
        }
        .onChange(of: store.isInstallingTools) { _, installing in
            guard !installing else { return }
            Task {
                missingTools = await Task.detached { ToolInstaller.missingTools }.value
            }
        }
    }
}

// MARK: - AI

private struct AISettingsTab: View {
    @Environment(AppStore.self) private var store

    // Optimistic until the async CLI check lands, mirroring the plan sheet.
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))

    /// The provider label with the same flags the plan sheet shows: the
    /// catalog's true top pick is always "★ recommended" (installed or
    /// not); when it's missing, the best installed one is flagged too.
    private func providerLabel(_ provider: AICatalog.Provider, task: String) -> String {
        var label = provider.label
        let chain = AICatalog.recommendedChains[task] ?? []
        let top = chain.first?.provider ?? AICatalog.taskDefaults[task]
        let bestAvailable = chain.first { availableProviders.contains($0.provider) }?.provider
        if provider.key == top {
            label += "  ★ recommended"
        } else if provider.key == bestAvailable, bestAvailable != top {
            label += "  ★ best available"
        }
        if !availableProviders.contains(provider.key) { label += "  (not installed)" }
        return label
    }

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Task Routing") {
                ForEach(AICatalog.tasks, id: \.self) { task in
                    Picker(AICatalog.taskLabels[task] ?? task, selection: Binding(
                        get: { store.settings.ai.tasks[task] ?? AICatalog.taskDefaults[task] ?? "claude" },
                        set: {
                            store.settings.ai.tasks[task] = $0
                            // A provider change invalidates the task's model pick.
                            store.settings.ai.taskModels[task] = nil
                        }
                    )) {
                        ForEach(AICatalog.providers, id: \.key) { provider in
                            Text(providerLabel(provider, task: task)).tag(provider.key)
                        }
                    }
                }
                Button("Reset Smart Dispatcher") {
                    store.resetDispatcher()
                }
                Text("Restores the recommended model for every task and re-enables the model-plan prompts shown before Analyze and Generate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .task {
            var available = Set<String>()
            for provider in AICatalog.providers {
                if await store.ai.isProviderAvailable(provider.key) {
                    available.insert(provider.key)
                }
            }
            availableProviders = available
        }
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
