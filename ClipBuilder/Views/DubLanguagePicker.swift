import SwiftUI

struct DubLanguagePicker: View {
    @Binding var language: String?
    @State private var voices: [DubSynthesizer.Voice]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Language", selection: Binding(get: { language ?? DubLanguageChoices.defaultLanguage }, set: { language = $0 })) {
                ForEach(DubLanguageChoices.languages(voices: voices ?? [], selected: language), id: \.self) { code in
                    Text(DubLanguageChoices.name(code)).tag(code)
                }
            }
            .lineLimit(1)
            if let voices {
                let count = voices.filter { DubLanguageChoices.matches($0.language, requested: language ?? DubLanguageChoices.defaultLanguage) }.count
                Text(count == 0 ? "Install voices in System Settings › Accessibility › Spoken Content" : "\(count) voices installed")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Loading Mac voices…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { voices = await DubLanguageChoices.voices() }
    }
}
