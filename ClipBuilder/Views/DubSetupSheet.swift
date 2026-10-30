import SwiftUI

struct DubSetupSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var language: String?
    @State private var originalLevel = 0.15
    @State private var replaceOriginal = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dub with \(store.dubEngine.title)").font(.headline)
            DubLanguagePicker(language: $language)
            HStack {
                Text("Original level").lineLimit(1).fixedSize()
                Slider(value: $originalLevel, in: 0...0.5)
                    .accessibilityLabel("Original speech level")
                    .disabled(replaceOriginal)
                Text(originalLevel, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().frame(width: 44)
            }
            Toggle("Mute original audio (speech and background)", isOn: $replaceOriginal)
            Text("Review each line before applying the dub. Playback starts only when you press Play.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    store.dubTimeline(language: language ?? DubLanguageChoices.defaultLanguage,
                                      originalLevel: originalLevel, replaceOriginal: replaceOriginal)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.spaceL).frame(width: 440)
        .modalCloseButton { dismiss() }
        .appJobSetupPresentation()
        .onAppear { language = store.builder.document.dub?.language ?? store.editingDefaults.footage.dubLanguage }
    }
}
