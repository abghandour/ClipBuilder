import Speech
import SwiftUI

struct ProjectLanguagesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRecord
    @State private var languages: ProjectLanguages
    @State private var spokenChoices: [String] = []
    @State private var dubChoices: [String] = []
    @State private var saving = false
    @State private var error: String?

    init(project: ProjectRecord) {
        self.project = project
        _languages = State(initialValue: project.languages ?? ProjectLanguages())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Languages — \(project.name)").font(.headline)
            Text("Shared with the team. Empty lists inherit the profile defaults; installation is checked on each Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                languageList("Spoken in footage", values: $languages.spoken, choices: spokenChoices)
                languageList("Caption and translation targets", values: $languages.captions,
                             choices: ["en", "pt", "es", "fr", "de", "it", "ja", "ko", "zh", "ar", "hi", "ru"])
                languageList("Dub targets", values: $languages.dub, choices: dubChoices)
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Use Profile Defaults") { languages = ProjectLanguages() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(saving)
            }
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
        }
        .appJobSetupPresentation()
        .padding(Theme.spaceL)
        .frame(width: 540, height: 540)
        .task {
            spokenChoices = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted {
                DubLanguageChoices.name($0).localizedStandardCompare(DubLanguageChoices.name($1)) == .orderedAscending
            }
            let voices = await DubLanguageChoices.voices(engine: store.editingDefaults.footage.dubEngine.flatMap(DubVoiceEngine.init(rawValue:)))
            dubChoices = DubLanguageChoices.languages(voices: voices)
        }
    }

    private func languageList(_ title: String, values: Binding<[String]>, choices: [String]) -> some View {
        Section(title) {
            ForEach(values.wrappedValue, id: \.self) { language in
                HStack {
                    Text(DubLanguageChoices.name(language))
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { values.wrappedValue.removeAll { $0 == language } }
                        .labelStyle(.iconOnly).help("Remove \(DubLanguageChoices.name(language))")
                }
            }
            if values.wrappedValue.isEmpty { Text("Use profile defaults").foregroundStyle(.secondary) }
            Menu("Add Language…") {
                ForEach(choices.filter { choice in
                    !values.wrappedValue.contains { ProjectLanguageResolver.unique([$0]) == ProjectLanguageResolver.unique([choice]) }
                }, id: \.self) { language in
                    Button(DubLanguageChoices.name(language)) {
                        values.wrappedValue = ProjectLanguageResolver.unique(values.wrappedValue + [language])
                    }
                }
            }
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                let inherited = languages == ProjectLanguages()
                try await store.saveProjectLanguages(inherited ? nil : languages, project: project)
                dismiss()
            } catch { self.error = error.userMessage; saving = false }
        }
    }
}
