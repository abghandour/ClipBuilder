import SwiftUI

struct DubLanguagePicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("settings.selectedTab") private var settingsTab = "profile"
    @Binding var language: String?
    @State private var voices: [DubSynthesizer.Voice]?
    @State private var showSetup = false
    @State private var connectionError: String?
    @State private var missingKey = false
    @State private var reloadID = 0
    @State private var refreshVoices = false

    private var selectedLanguage: String { language ?? DubLanguageChoices.defaultLanguage }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsRow("Voices") {
                Picker("Voices", selection: Binding(get: { store.dubEngine }, set: { choose($0) })) {
                    ForEach(DubVoiceEngine.allCases, id: \.self) { engine in
                        Text(engine.title).lineLimit(1).fixedSize().tag(engine)
                    }
                }
            }
            SettingsRow("Language") {
                Picker("Language", selection: Binding(get: { selectedLanguage }, set: { language = $0 })) {
                    ForEach(DubLanguageChoices.languages(voices: voices ?? [], selected: language,
                                                        engine: store.dubEngine), id: \.self) { code in
                        Text(DubLanguageChoices.name(code)).lineLimit(1).fixedSize().tag(code)
                    }
                }
            }
            if let voices {
                let count = voices.filter { DubLanguageChoices.matches($0.language, requested: selectedLanguage) }.count
                HStack(spacing: 8) {
                    Text(caption(count: count))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                        .help(caption(count: count))
                    if store.dubEngine == .siri {
                        Button(count == 0 ? "Set up…" : "Manage…") { showSetup = true }
                            .controlSize(.small).lineLimit(1).fixedSize()
                    } else if store.dubEngine == .elevenLabs {
                        if missingKey {
                            Button("Open Settings…") {
                                settingsTab = "ai"
                                openSettings()
                            }
                            .controlSize(.small).lineLimit(1).fixedSize()
                        } else {
                            Button("Manage…") {
                                refreshVoices = true
                                reloadID += 1
                            }
                            .controlSize(.small).lineLimit(1).fixedSize()
                            .help("Refresh your ElevenLabs voices")
                        }
                    }
                }
            } else {
                Text("Loading \(store.dubEngine.title.lowercased())…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: ReloadKey(engine: store.dubEngine, language: selectedLanguage, revision: reloadID)) { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reloadID += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: ElevenLabsVoices.settingsChanged)) { _ in
            if store.dubEngine == .elevenLabs { reloadID += 1 }
        }
        .sheet(isPresented: $showSetup, onDismiss: { reloadID += 1 }) {
            SiriDubSetupSheet(language: selectedLanguage)
        }
    }

    private func caption(count: Int) -> String {
        switch (store.dubEngine, count) {
        case (.mac, 0): "Install voices in System Settings → Accessibility → Spoken Content"
        case (.mac, _): "\(count) voices installed"
        case (.siri, 0): "Siri voices need a one-time setup for \(DubLanguageChoices.name(selectedLanguage))"
        case (.siri, _): "\(count) Siri voices ready"
        case (.elevenLabs, _): connectionError ?? "\(count) ElevenLabs voices"
        }
    }

    /// Switching to Siri opens the setup sheet when no voice is ready yet.
    private func choose(_ engine: DubVoiceEngine) {
        store.dubEngine = engine
        voices = nil
        guard engine == .siri else { return }
        let code = selectedLanguage
        Task {
            if await SiriDubVoices.readyVoices(language: code).isEmpty { showSetup = true }
        }
    }

    private func reload() async {
        let engine = store.dubEngine
        let language = selectedLanguage
        let refresh = refreshVoices
        refreshVoices = false
        voices = nil
        connectionError = nil
        missingKey = false
        if engine == .elevenLabs {
            do {
                let cached = try await (refresh ? ElevenLabsVoiceCache.shared.refresh() : ElevenLabsVoiceCache.shared.voices())
                try Task.checkCancellation()
                voices = ElevenLabsVoices.voices(from: cached, language: language)
            } catch {
                guard !Task.isCancelled else { return }
                connectionError = (error as? ElevenLabsError)?.userMessage ?? error.localizedDescription
                missingKey = (error as? ElevenLabsError) == .invalidKey
                voices = []
            }
        } else {
            let loaded = await DubLanguageChoices.voices(engine: engine)
            guard !Task.isCancelled else { return }
            voices = loaded
        }
    }

    private struct ReloadKey: Equatable {
        var engine: DubVoiceEngine
        var language: String
        var revision: Int
    }
}
