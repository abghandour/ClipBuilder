import SwiftUI

/// Provider + model pickers for a few AI tasks, bound to the same routing
/// Settings → AI edits, so a choice made here is the choice everywhere and
/// survives relaunches. Used by the Wizard form to show the models a run
/// will use without a detour to Settings.
struct TaskModelPickers: View {
    @Environment(AppStore.self) private var store
    let tasks: [String]
    /// Outside a Form nothing lines the rows up: a fixed label column and a
    /// fixed menu width keep every dropdown on the same two edges.
    var labelWidth: CGFloat?
    var menuWidth: CGFloat = 330
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))

    var body: some View {
        ForEach(tasks, id: \.self) { task in
            let title = AICatalog.taskLabels[task] ?? task
            let help = Self.help[task] ?? "The provider and model for this task; the same setting as Settings → AI → Task Routing."
            if let labelWidth {
                HStack(spacing: 8) {
                    Text(title)
                        .lineLimit(1)
                        .frame(width: labelWidth, alignment: .leading)
                    ModelPicker(title: title, task: task,
                                selection: routingBinding(for: task), availableProviders: availableProviders)
                        .labelsHidden()
                        .frame(width: menuWidth)
                }
                .help(help)
            } else {
                ModelPicker(title: title, task: task,
                            selection: routingBinding(for: task), availableProviders: availableProviders)
                    .help(help)
            }
        }
        .task { availableProviders = await ModelPicker.probeAvailability(ai: store.ai) }
    }

    static func routingSummary(task: String, config: AIConfig) -> String {
        let configured = config.tasks[task]
        let provider = configured.flatMap { AICatalog.provider($0) != nil ? $0 : nil }
            ?? AICatalog.taskDefaults[task] ?? "claude"
        let taskModel = config.taskModels[task].flatMap { $0.isEmpty ? nil : $0 }
        let providerModel = (config.providers[provider]?.model).flatMap { $0.isEmpty ? nil : $0 }
        let model = taskModel ?? providerModel ?? AICatalog.provider(provider)?.defaultModel ?? "Automatic"
        return "\(AICatalog.provider(provider)?.label ?? provider) · \(AICatalog.modelDisplayName(model))"
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
                let config = store.effectiveAIConfig
                let provider = config.tasks[task] ?? AICatalog.taskDefaults[task] ?? "claude"
                let model = config.taskModels[task]
                    ?? config.providers[provider]?.model
                    ?? AICatalog.provider(provider)?.defaultModel ?? ""
                return ModelPicker.tag(provider: provider, model: model)
            },
            set: {
                let parsed = ModelPicker.parse($0)
                // Settings saves when its screen closes; here the choice is
                // saved at once so it survives a quit from the Wizard.
                store.setTaskModel(task: task, provider: parsed.provider, model: parsed.model)
            }
        )
    }
}
