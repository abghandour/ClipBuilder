import SwiftUI

struct DubSetupSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var language: String?
    @State private var originalLevel = 0.15
    @State private var replaceOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dub with Mac voices").font(.title3.bold())
            DubLanguagePicker(language: $language)
            HStack {
                Text("Original level").lineLimit(1).fixedSize()
                Slider(value: $originalLevel, in: 0...0.5)
                    .accessibilityLabel("Original speech level")
                    .disabled(replaceOriginal)
                Text(originalLevel, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().frame(width: 44)
            }
            Toggle("Replace original speech", isOn: $replaceOriginal)
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
        .padding(20).frame(width: 440)
        .appJobSetupPresentation()
        .onAppear { language = store.builder.document.dub?.language ?? store.editingDefaults.footage.dubLanguage }
    }
}
