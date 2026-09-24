import SwiftUI

/// Profile starter: a short brand interview the AI turns into a founding
/// taste rubric, house style, and starter video-type categories — reviewed
/// and editable before anything is written into the profile. Studying real
/// reels later refines what this seeds.
struct ProfileStarterSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var audience = ""
    @State private var tone = ""
    @State private var inspiration = ""
    @State private var avoid = ""

    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))

    var body: some View {
        interview
        .frame(minWidth: 540, idealWidth: 580, minHeight: 380, idealHeight: 520)
        .appJobSetupPresentation()
        .modalCloseButton { dismiss() }
        .task {
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
            if modelTag.isEmpty {
                modelTag = ModelPicker.bestAvailableTag(for: "onboard",
                                                        available: availableProviders)
            }
        }
    }

    private var interview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate Starting Style")
                .font(.title3.bold())
            Text("Answer what you can — the AI writes this profile's founding taste rubric, house style, and starter video-type categories from it. You review and edit everything before it's saved. Learning from real reels later refines these.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Who is the content for?", text: $audience, axis: .vertical)
                    .lineLimit(1...3)
                TextField("Tone and personality?", text: $tone, axis: .vertical)
                    .lineLimit(1...3)
                TextField("Accounts or creators you admire, and why?", text: $inspiration, axis: .vertical)
                    .lineLimit(1...3)
                TextField("What should never be posted?", text: $avoid, axis: .vertical)
                    .lineLimit(1...3)
            }
            .formStyle(.columns)

            HStack {
                ModelPicker(title: "Model", task: "onboard", selection: $modelTag,
                            availableProviders: availableProviders)
                    .fixedSize()
                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Generate") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled([audience, tone, inspiration, avoid]
                                  .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(20)
    }

    private func run() {
        let store = store
        let audience = audience, tone = tone, inspiration = inspiration, avoid = avoid
        let (provider, model) = ModelPicker.parse(modelTag)
        store.jobs.start(.profileStarter, title: "Generate Starting Style",
                         project: nil, profileGeneration: store.profileGeneration) { log in
            let result = try await store.generateProfileStarter(
                audience: audience, tone: tone, inspiration: inspiration, avoid: avoid,
                provider: provider, model: model, log: log)
            return .profileStarter(result.value, provenance: result.provenance)
        }
        dismiss()
    }
}
