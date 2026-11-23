import SwiftUI

struct BuilderDubToggle: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var model = store.builder
        if model.document.dubLines?.isEmpty == false {
            Toggle(isOn: $model.liveDubEnabled) {
                Label("Dub", systemImage: "waveform.badge.mic").lineLimit(1).fixedSize()
            }
            .toggleStyle(.button).controlSize(.small).fixedSize()
            .help("Hear the dub in live preview. Exact preview and export use the dub's export settings.")
        }
    }
}
