import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        TabView {
            ProfileSettingsTab()
                .tabItem { Label("Profile", systemImage: "person.crop.square") }
            TasteSettingsTab()
                .tabItem { Label("Taste", systemImage: "graduationcap") }
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
            InstagramSettingsTab()
                .tabItem { Label("Instagram", systemImage: "play.rectangle.on.rectangle") }
        }
        .frame(width: 560, height: 520)
        // Fields edit the live store; closing the window persists them, so
        // the Save buttons are a convenience rather than a requirement.
        .onDisappear {
            store.saveSettings()
            store.saveActiveProfile()
        }
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
            Section("Account") {
                TextField("Instagram handle", text: Binding(
                    get: { store.activeProfile.socials["instagram"]?.handle ?? "" },
                    set: { store.activeProfile.socials["instagram", default: SocialSlot()].handle = $0 }
                ), prompt: Text("@yourbrand"))
                Text("The profile's own handle — used as the default account for fetches and tests. Saved with the profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                    Text("Paste a long-lived access token from a Meta app with instagram_basic and instagram_manage_insights (add instagram_content_publish to publish reels from the Library), for the Facebook page linked to your business/creator account. Stored in the Keychain, never in settings files.")
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
                    store.saveActiveProfile()   // the handle lives on the profile
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
            }

            Section("Fight Research Sources") {
                ForEach(BrandProfile.knownBuzzSources, id: \.key) { source in
                    Toggle(source.label, isOn: Binding(
                        get: { store.activeProfile.buzzSources.contains(source.key) },
                        set: { enabled in
                            if enabled {
                                if !store.activeProfile.buzzSources.contains(source.key) {
                                    store.activeProfile.buzzSources.append(source.key)
                                }
                            } else {
                                store.activeProfile.buzzSources.removeAll { $0 == source.key }
                            }
                        }))
                }
                TextField("Extra sources", text: $store.activeProfile.buzzExtraSources,
                          prompt: Text("r/ufc, mmamania.com — comma-separated"))
                Text("Crawled with plain web requests (Reddit's public API, site-scoped search) when you run Fight Research from the Analyze page — no logins, which is why X and Instagram aren't offered. The distilled story is saved on the video and the wizards can build the reel's narrative and captions from it. Saved with the profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

// MARK: - Taste

/// Everything taste learning: the global rubric, exemplar frames, local
/// sample studies, and the learned video-type categories. Reels teach it
/// from the Instagram screen ("Learn"); this tab is where the lessons live.
private struct TasteSettingsTab: View {
    @Environment(AppStore.self) private var store
    @State private var deletingCategory: TasteCategory?

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Taste Rubric") {
                Text("What a keeper moment looks like — this profile-wide rubric is yours to write and edit by hand; it rides into every analysis (as the \"highlight\" tag) and every wizard plan. Learning from sample reels refines the per-video-type rubrics below, not this one.")
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
                    Button("Learn from Sample Video…") {
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
                        Text("Learning…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("House Style") {
                Text("What ALL the reels you study have in common — hook types, duration and pacing, structure, overlay and music habits — distilled across every analyzed Instagram reel and weighted by performance. The wizard follows it on every run; a specific reference reel still outranks it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !store.activeProfile.houseStyle.isEmpty {
                    TextEditor(text: $store.activeProfile.houseStyle)
                        .font(.body)
                        .frame(minHeight: 110)
                }
                HStack {
                    Button("Distill House Style from Analyzed Reels") {
                        store.distillHouseStyle()
                    }
                    .disabled(store.isDistillingHouseStyle)
                    .help("Reads every reel template analysis (Instagram → Analyze Reel) and merges their shared patterns into the house style above")
                    if store.isDistillingHouseStyle {
                        ProgressView()
                            .controlSize(.small)
                        Text("Distilling…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Learned Video Types") {
                if store.activeProfile.tasteCategories.isEmpty {
                    Text("Nothing learned yet. Select reels on the Instagram screen and use the Learn menu — each reel is classified into a video type (fight highlights, interviews, …) whose rubric it refines. The AI Wizard's Video type picker lists them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Each learned reel refines one of these rubrics. The AI Wizard's Video type picker lists them.")
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
                                Button("Delete Type…", role: .destructive) {
                                    deletingCategory = category
                                }
                                .controlSize(.small)
                            }
                        } label: {
                            Text("\(category.label) · learned from \(category.studiedCount) reel(s)")
                        }
                    }
                }
            }

            Section("Wizard Brain") {
                Text("Everything the wizard has learned that travels — pinned and distilled lessons, taste rubric, video-type rubrics with their example frames, and the house style — as one JSON file. Back it up (it diffs cleanly in git) or hand it to another user; importing merges and never overwrites what you already have.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Export Wizard Brain…") {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.json]
                        panel.nameFieldStringValue = "WizardBrain-\(store.activeProfile.profileName).json"
                        if panel.runModal() == .OK, let url = panel.url {
                            store.exportWizardBrain(to: url)
                        }
                    }
                    Button("Import Wizard Brain…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.json]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            store.importWizardBrain(from: url)
                        }
                    }
                }
                if let status = store.wizardBrainStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
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
        .confirmationDialog("Delete the \"\(deletingCategory?.label ?? "")\" video type?",
                            isPresented: Binding(get: { deletingCategory != nil },
                                                 set: { if !$0 { deletingCategory = nil } })) {
            Button("Delete Video Type", role: .destructive) {
                if let category = deletingCategory {
                    store.removeTasteCategory(key: category.key)
                }
                deletingCategory = nil
            }
            Button("Cancel", role: .cancel) { deletingCategory = nil }
        } message: {
            Text("Its learned rubric and example frames are removed. Reels that taught it would need to be learned again.")
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
                Text("Visual suits action footage; speech-first suits interviews and tutorials. Speech-first scene detection is not ported yet — transcription itself is available from the Raw Videos screen.")
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

            Section("Transitions") {
                LabeledContent("Crossfade duration") {
                    HStack {
                        Slider(value: $store.settings.transitions.xfadeDuration, in: 0.1...1.0, step: 0.05)
                            .frame(width: 180)
                        Text(String(format: "%.2fs", store.settings.transitions.xfadeDuration))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                Text("How long crossfade transitions overlap. Action edits feel best at 0.15-0.35s; flash cuts and action transitions (knife slash, zoom punch, whip…) carry their own fixed timings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Transition sound effects", isOn: $store.settings.transitions.sfxEnabled)
                Text("Mixes a synthesized whoosh, impact, or slash under action transitions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Snap wizard cuts to music beats", isOn: $store.settings.transitions.beatSnap)
                Text("After the AI plans a reel, each cut is nudged (up to ±0.35s) onto the nearest strong beat of the selected music.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            }

            Section("Required Tools") {
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

    /// One "provider|model" binding per task, writing both routing fields.
    private func routingBinding(for task: String) -> Binding<String> {
        Binding(
            get: {
                let provider = store.settings.ai.tasks[task]
                    ?? AICatalog.taskDefaults[task] ?? "claude"
                let model = store.settings.ai.taskModels[task]
                    ?? store.settings.ai.providers[provider]?.model
                    ?? AICatalog.provider(provider)?.defaultModel ?? ""
                return ModelPicker.tag(provider: provider, model: model)
            },
            set: {
                let parsed = ModelPicker.parse($0)
                store.settings.ai.tasks[task] = parsed.provider
                store.settings.ai.taskModels[task] = parsed.model
            }
        )
    }

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Task Routing") {
                ForEach(AICatalog.tasks, id: \.self) { task in
                    ModelPicker(title: AICatalog.taskLabels[task] ?? task,
                                task: task, selection: routingBinding(for: task),
                                availableProviders: availableProviders)
                }
                Button("Reset to Recommended Models") {
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
                            Text(AICatalog.modelDisplayName(model)).tag(model)
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
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
        }
        // A just-installed CLI should show up in the routing pickers too.
        .onChange(of: store.installingProviderCLIs) { _, installing in
            guard installing.isEmpty else { return }
            Task { availableProviders = await ModelPicker.probeAvailability(ai: store.ai) }
        }
    }
}

private struct AvailabilityRow: View {
    @Environment(AppStore.self) private var store
    let providerKey: String
    @State private var available: Bool?

    private var isInstalling: Bool { store.installingProviderCLIs.contains(providerKey) }

    var body: some View {
        LabeledContent("Status") {
            switch available {
            case .none:
                ProgressView().controlSize(.small)
            case .some(true):
                Text("Installed").foregroundStyle(.green)
            case .some(false):
                HStack(spacing: 8) {
                    Text("Not found").foregroundStyle(.red)
                    if isInstalling {
                        ProgressView().controlSize(.small)
                        Text("Installing…").foregroundStyle(.secondary)
                    } else if ProviderCLIInstaller.canInstall(providerKey) {
                        Button("Install") {
                            store.installProviderCLI(providerKey)
                        }
                        .controlSize(.small)
                        .help("Downloads and installs this CLI (progress in the Analyze screen's activity log). You'll still need to sign in once by running it in Terminal.")
                    }
                }
            }
        }
        .task(id: providerKey) {
            available = await store.ai.isProviderAvailable(providerKey)
        }
        .onChange(of: isInstalling) { _, installing in
            guard !installing else { return }
            Task { available = await store.ai.isProviderAvailable(providerKey) }
        }
    }
}
