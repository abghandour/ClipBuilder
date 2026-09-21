import SwiftUI

struct WizardPodcastControls: View {
    let plan: WizardFormPlan
    @Binding var framing: String
    @Binding var useBRoll: Bool
    @Binding var instructions: String

    var body: some View {
        if plan.capabilities.cameraFocus {
            Picker("Camera focus", selection: $framing) {
                Text("Let AI choose the best").tag("")
                ForEach(CropRecipe.Kind.allCases, id: \.rawValue) { kind in
                    Text(kind.name).tag(kind.rawValue)
                }
            }
            Text(CropRecipe.Kind(rawValue: framing)?.summary ?? "Choose the framing that suits each highlight.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if plan.capabilities.bRoll {
            Toggle("Use B-roll", isOn: $useBRoll)
            if useBRoll {
                VStack(alignment: .leading, spacing: 6) {
                    Text("B-roll instructions").font(.callout)
                    TextEditor(text: $instructions)
                        .frame(minHeight: 70, maxHeight: 130)
                        .accessibilityLabel("B-roll instructions")
                    Text("e.g. use fight footage of the guest when he talks about his fights; never cover the host")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
