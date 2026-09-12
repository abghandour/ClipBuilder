import SwiftUI

struct BuilderScriptParameterForm: View {
    @Bindable var model: ScriptLibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            ForEach(model.header?.params ?? [], id: \.name) { parameter in
                VStack(alignment: .leading, spacing: Theme.spaceXS) {
                    Text(parameter.label ?? parameter.name).font(.caption).fontWeight(.medium)
                    if ["clip", "scene", "track", "choice", "boolean"].contains(parameter.type) {
                        Picker(parameter.label ?? parameter.name, selection: valueBinding(parameter.name)) {
                            Text("Choose…").tag("")
                            ForEach(model.choices(for: parameter)) { choice in
                                Text(choice.label).tag(choice.id)
                            }
                        }
                        .labelsHidden()
                        .help("Choose \(parameter.name) from the captured session.")
                    } else {
                        TextField(parameter.type == "time" ? "Seconds" : parameter.type,
                                  text: valueBinding(parameter.name))
                            .textFieldStyle(.roundedBorder)
                            .help("Enter \(parameter.name). \(rangeDescription(parameter))")
                    }
                }
            }
        }
        .disabled(model.capture == nil || model.busy)
    }

    private func valueBinding(_ name: String) -> Binding<String> {
        Binding(get: { model.values[name] ?? "" }, set: { model.values[name] = $0 })
    }

    private func rangeDescription(_ p: ScriptHeader.Parameter) -> String {
        [p.min.map { "Minimum \($0)." }, p.max.map { "Maximum \($0)." }, p.step.map { "Step \($0)." }]
            .compactMap { $0 }.joined(separator: " ")
    }
}
