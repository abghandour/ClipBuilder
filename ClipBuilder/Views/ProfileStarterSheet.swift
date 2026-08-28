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

    @State private var isRunning = false
    @State private var statusLine = ""
    @State private var errorMessage: String?
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))

    /// Generated documents, editable in the review phase.
    @State private var rubric = ""
    @State private var houseStyle = ""
    @State private var categories: [TasteCategory] = []
    @State private var hasResult = false
    /// The model that wrote the drafts — stamped on the profile when applied.
    @State private var provenance: AIProvenance?
    @State private var applyRubric = true
    @State private var applyHouseStyle = true
    @State private var applyCategories = true

    var body: some View {
        Group {
            if hasResult {
                review
            } else {
                interview
            }
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 380, idealHeight: 520)
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

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusLine.isEmpty ? "Writing the style documents…" : statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(isRunning ? "Generating…" : "Generate") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning
                              || [audience, tone, inspiration, avoid]
                                  .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(20)
    }

    private var review: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text("Review the generated style")
                        .font(.headline)
                    if let provenance {
                        ProvenanceBadge(provenance: provenance, style: .full, role: "Written by")
                    }
                }
                Text("Edit anything, uncheck what you don't want written, then Apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(store.activeProfile.tasteRubric.isEmpty
                           ? "Taste rubric"
                           : "Taste rubric (replaces the current one)", isOn: $applyRubric)
                        .font(.callout.bold())
                    TextEditor(text: $rubric)
                        .font(.callout)
                        .frame(minHeight: 90)
                        .disabled(!applyRubric)

                    Toggle(store.activeProfile.houseStyle.isEmpty
                           ? "House style"
                           : "House style (replaces the current one)", isOn: $applyHouseStyle)
                        .font(.callout.bold())
                    TextEditor(text: $houseStyle)
                        .font(.callout)
                        .frame(minHeight: 90)
                        .disabled(!applyHouseStyle)

                    if !categories.isEmpty {
                        Toggle("Video-type categories (\(categories.map(\.label).joined(separator: ", "))) — added alongside existing ones",
                               isOn: $applyCategories)
                            .font(.callout.bold())
                        ForEach(categories) { category in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.label)
                                    .font(.caption.bold())
                                Text(category.rubric)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            HStack {
                Spacer()
                Button("Apply to Profile") {
                    store.applyProfileStarter(
                        ProfileStarter.Result(rubric: rubric, houseStyle: houseStyle,
                                              categories: categories),
                        rubric: applyRubric, houseStyle: applyHouseStyle,
                        categories: applyCategories, provenance: provenance)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!applyRubric && !applyHouseStyle && !applyCategories)
            }
            .padding()
        }
    }

    private func run() {
        let (provider, model) = ModelPicker.parse(modelTag)
        isRunning = true
        errorMessage = nil
        Task {
            do {
                let result = try await store.generateProfileStarter(
                    audience: audience, tone: tone, inspiration: inspiration, avoid: avoid,
                    provider: provider, model: model) { message in
                    if let line = AIProgressLine.from(message) { Task { @MainActor in statusLine = line } }
                }
                rubric = result.value.rubric
                houseStyle = result.value.houseStyle
                categories = result.value.categories
                provenance = result.provenance
                hasResult = true
            } catch {
                errorMessage = error.userMessage
            }
            isRunning = false
        }
    }
}
