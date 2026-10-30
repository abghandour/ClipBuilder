import SwiftUI

struct DubLanguagePicker: View {
    @Environment(AppStore.self) private var store
    @Binding var language: String?
    @State private var voices: [DubSynthesizer.Voice]?
    @State private var showSetup = false

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
                    ForEach(DubLanguageChoices.languages(voices: voices ?? [], selected: language), id: \.self) { code in
                        Text(DubLanguageChoices.name(code)).lineLimit(1).fixedSize().tag(code)
                    }
                }
            }
            if let voices {
                let count = voices.filter { DubLanguageChoices.matches($0.language, requested: selectedLanguage) }.count
                HStack(spacing: 8) {
                    Text(caption(count: count))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.dubEngine == .siri {
                        Button(count == 0 ? "Set up…" : "Manage…") { showSetup = true }
                            .controlSize(.small).lineLimit(1).fixedSize()
                    }
                }
            } else {
                Text("Loading \(store.dubEngine.title.lowercased())…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: store.dubEngine) { await reload() }
        .sheet(isPresented: $showSetup, onDismiss: { Task { await reload() } }) {
            SiriDubSetupSheet(language: selectedLanguage)
        }
    }

    private func caption(count: Int) -> String {
        switch (store.dubEngine, count) {
        case (.mac, 0): "Install voices in System Settings → Accessibility → Spoken Content"
        case (.mac, _): "\(count) voices installed"
        case (.siri, 0): "Siri voices need a one-time setup for \(DubLanguageChoices.name(selectedLanguage))"
        case (.siri, _): "\(count) Siri voices ready"
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
        voices = await DubLanguageChoices.voices(engine: store.dubEngine)
    }
}
