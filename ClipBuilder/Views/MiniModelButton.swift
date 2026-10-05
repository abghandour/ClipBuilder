import SwiftUI

/// The gear beside a Mini control that uses an AI model: a popover with the
/// provider and model for that job. The choice is the shared task routing
/// (Settings → AI), so it is remembered and applies everywhere.
struct MiniModelButton: View {
    @Environment(AppStore.self) private var store
    /// AI task keys (`AITask` raw values), most important first.
    let tasks: [String]
    @State private var showing = false

    private var labels: String {
        tasks.map { AICatalog.taskLabels[$0] ?? $0 }.joined(separator: ", ")
    }

    var body: some View {
        Button("AI model for \(labels)", systemImage: "gearshape") { showing = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Choose the AI model for: \(labels). Now: "
                  + tasks.map { TaskModelPickers.routingSummary(task: $0, config: store.settings.ai) }.joined(separator: "; "))
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: Theme.spaceM) {
                    Text("AI model").font(.headline)
                    TaskModelPickers(tasks: tasks, labelWidth: 150, menuWidth: 300)
                    FormCaption("Remembered for every run and used wherever the app does this job.")
                }
                .padding(Theme.spaceL)
                .frame(width: 520)
            }
    }
}
