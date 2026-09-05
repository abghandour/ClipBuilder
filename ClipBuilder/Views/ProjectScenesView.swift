import SwiftUI

struct ProjectScenesView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            Picker(
                "Scenes",
                selection: Binding(
                    get: { Mode(rawValue: store.sceneMode) ?? .all },
                    set: { store.sceneMode = $0.rawValue }
                )
            ) {
                Text("All").tag(Mode.all)
                Text("Curated").tag(Mode.curated)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .padding(.vertical, Theme.spaceS)

            Divider()

            if store.sceneMode == Mode.all.rawValue {
                ScenesView()
            } else {
                ScenesView(curatedOnly: true)
            }
        }
    }

    private enum Mode: String {
        case all
        case curated
    }
}
