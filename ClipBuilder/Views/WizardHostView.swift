import SwiftUI

struct WizardHostView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store

        PageTabs(tabs: WizardMode.allCases, selection: $store.wizardMode, label: \.label,
                 fills: true, padding: 0) { mode in
            switch mode {
            case .full:
                WizardView()
            case .express:
                MiniWizardView(profileName: store.activeProfile.profileName)
                    .id(store.activeProfile.profileName)
            }
        }
        .padding(Theme.spaceS)
        .accessibilityLabel("Wizard mode")
        .askAI(WizardAssistant())
    }
}
