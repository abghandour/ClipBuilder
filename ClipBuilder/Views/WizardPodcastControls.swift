import SwiftUI

struct WizardPodcastControls: View {
    let plan: WizardFormPlan
    @Binding var useBRoll: Bool
    @Binding var instructions: String

    var body: some View {
        if plan.capabilities.bRoll {
            Toggle("Use B-roll", isOn: $useBRoll)
            if useBRoll {
                DisclosureGroup("B-roll instructions") {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 70, maxHeight: 130)
                        .accessibilityLabel("B-roll instructions")
                    FormCaption("e.g. use fight footage of the guest when he talks about his fights; never cover the host")
                }
            }
        }
    }
}
