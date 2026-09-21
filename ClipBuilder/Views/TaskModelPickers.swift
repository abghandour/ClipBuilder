import SwiftUI

/// Provider + model pickers for a few AI tasks, bound to the same routing
/// Settings → AI edits, so a choice made here is the choice everywhere and
/// survives relaunches. Used by the Wizard form to show the models a run
/// will use without a detour to Settings.
struct TaskModelPickers: View {
    @Environment(AppStore.self) private var store
    let tasks: [String]
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))

    var body: some View {
        ForEach(tasks, id: \.self) { task in
            ModelPicker(title: AICatalog.taskLabels[task] ?? task, task: task,
                        selection: routingBinding(for: task), availableProviders: availableProviders)
                .help(Self.help[task] ?? "The provider and model for this task; the same setting as Settings → AI → Task Routing.")
        }
        .task { availableProviders = await ModelPicker.probeAvailability(ai: store.ai) }
    }

    private static let help: [String: String] = [
        "highlights": "Finds the reel-worthy runs inside long exchanges and titles them. Same setting as Settings → AI.",
        "wizard": "Plans the reel from the scenes. Same setting as Settings → AI.",
        "critique": "Reviews each version when the critique loop is on. Same setting as Settings → AI.",
        "captions": "Writes captions and the post text. Same setting as Settings → AI.",
    ]

    /// One "provider|model" binding per task, writing both routing fields.
    private func routingBinding(for task: String) -> Binding<String> {
        Binding(
            get: {
                let provider = store.settings.ai.tasks[task] ?? AICatalog.taskDefaults[task] ?? "claude"
                let model = store.settings.ai.taskModels[task]
                    ?? store.settings.ai.providers[provider]?.model
                    ?? AICatalog.provider(provider)?.defaultModel ?? ""
                return ModelPicker.tag(provider: provider, model: model)
            },
            set: {
                let parsed = ModelPicker.parse($0)
                store.settings.ai.tasks[task] = parsed.provider
                store.settings.ai.taskModels[task] = parsed.model
                // Settings saves when its screen closes; here the choice is
                // saved at once so it survives a quit from the Wizard.
                store.saveSettings()
            }
        )
    }
}
