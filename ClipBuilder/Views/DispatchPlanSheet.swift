import SwiftUI

/// Which user action a dispatch plan gates.
enum DispatchOperation: String {
    case analyze
    case generate

    var title: String {
        switch self {
        case .analyze: return "Model plan for analysis"
        case .generate: return "Model plan for generation"
        }
    }

    /// AI-dispatched stages, in pipeline order.
    var aiTasks: [String] {
        switch self {
        case .analyze: return ["analysis"]
        case .generate: return ["research", "wizard", "captions", "parse"]
        }
    }

    /// Stages that run on-device — shown for transparency, nothing to pick.
    var localStages: [(label: String, detail: String)] {
        switch self {
        case .analyze:
            return [("Transcription", "Apple SpeechAnalyzer — runs on this Mac"),
                    ("Scene detection", "derived from the analysis tags — local")]
        case .generate:
            return [("Video assembly", "ffmpeg — runs on this Mac")]
        }
    }
}

/// An operation waiting for its model plan to be confirmed.
struct PendingDispatch: Identifiable {
    let id = UUID()
    var operation: DispatchOperation
    var run: () -> Void
}

/// The smart dispatcher's pre-flight sheet: which model handles each stage
/// of the operation, editable, with a "remember" checkbox that mutes the
/// prompt for this operation type (reset from Settings → AI).
struct DispatchPlanSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let operation: DispatchOperation
    let onStart: () -> Void

    /// task → "provider|model" (Picker-friendly composite tag).
    @State private var choices: [String: String] = [:]
    @State private var remember = false
    // Optimistic until the async CLI check lands, so the sheet never blocks.
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(operation.title)
                    .font(.headline)
                Text("The dispatcher picked the best available model for each step. Adjust if you like — if a model fails mid-run, the next best available takes over automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Form {
                ForEach(operation.aiTasks, id: \.self) { task in
                    Picker(AICatalog.taskLabels[task] ?? task, selection: binding(for: task)) {
                        ForEach(options(for: task), id: \.tag) { option in
                            Text(option.label).tag(option.tag)
                        }
                    }
                }
                ForEach(operation.localStages, id: \.label) { stage in
                    LabeledContent(stage.label) {
                        Text(stage.detail)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: CGFloat(operation.aiTasks.count + operation.localStages.count) * 44 + 60)

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Remember these choices and don't ask again", isOn: $remember)
                Text("You can reset the dispatcher's choices and re-enable this prompt in Settings → AI.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Start") { start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 460)
        .task {
            var available = Set<String>()
            for provider in AICatalog.providers {
                if await store.ai.isProviderAvailable(provider.key) {
                    available.insert(provider.key)
                }
            }
            availableProviders = available
            seedChoices()
        }
        .onAppear(perform: seedChoices)
    }

    // MARK: - Choices

    private func binding(for task: String) -> Binding<String> {
        Binding(get: { choices[task] ?? recommendedTag(for: task) },
                set: { choices[task] = $0 })
    }

    /// First recommended chain entry whose CLI is installed, else the
    /// task default provider with its default model.
    private func recommendedTag(for task: String) -> String {
        for entry in AICatalog.recommendedChains[task] ?? []
        where availableProviders.contains(entry.provider) {
            return "\(entry.provider)|\(entry.model)"
        }
        let key = AICatalog.taskDefaults[task] ?? "claude"
        return "\(key)|\(AICatalog.provider(key)?.defaultModel ?? "")"
    }

    /// Current effective choice: the user's saved routing when present,
    /// otherwise the recommendation.
    private func seedChoices() {
        guard choices.isEmpty else { return }
        for task in operation.aiTasks {
            if let provider = store.settings.ai.tasks[task] {
                let model = store.settings.ai.taskModels[task]
                    ?? store.settings.ai.providers[provider]?.model
                    ?? AICatalog.provider(provider)?.defaultModel ?? ""
                choices[task] = "\(provider)|\(model)"
            } else {
                choices[task] = recommendedTag(for: task)
            }
        }
    }

    private func options(for task: String) -> [(tag: String, label: String)] {
        let recommended = recommendedTag(for: task)
        var result: [(String, String)] = []
        for provider in AICatalog.providers {
            let installed = availableProviders.contains(provider.key)
            for model in provider.models {
                let tag = "\(provider.key)|\(model)"
                var label = "\(provider.label) — \(model)"
                if tag == recommended { label += "  ★ recommended" }
                if !installed { label += "  (not installed)" }
                result.append((tag, label))
            }
        }
        // Keep whatever is currently chosen selectable even if it's custom.
        if let current = choices[task], !result.contains(where: { $0.0 == current }) {
            result.append((current, current.replacingOccurrences(of: "|", with: " — ")))
        }
        return result
    }

    private func start() {
        for task in operation.aiTasks {
            let tag = choices[task] ?? recommendedTag(for: task)
            let parts = tag.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { continue }
            store.settings.ai.tasks[task] = String(parts[0])
            store.settings.ai.taskModels[task] = String(parts[1])
        }
        if remember, !store.settings.ai.mutedDispatchPlans.contains(operation.rawValue) {
            store.settings.ai.mutedDispatchPlans.append(operation.rawValue)
        }
        store.saveSettings()
        dismiss()
        onStart()
    }
}
