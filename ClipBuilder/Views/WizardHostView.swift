import SwiftUI

struct WizardHostView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            HStack {
                Picker("Wizard mode", selection: $store.wizardMode) {
                    ForEach(WizardMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, Theme.spaceM)
            .padding(.vertical, Theme.spaceS)
            .background(.bar)
            Divider()

            switch store.wizardMode {
            case .full:
                WizardView()
            case .express:
                MiniWizardView(profileName: store.activeProfile.profileName)
                    .id(store.activeProfile.profileName)
            }
        }
    }
}
