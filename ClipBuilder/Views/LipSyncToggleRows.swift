import SwiftUI

/// Under Dub in the Audio panel (Express and the full wizard): re-time the
/// speakers' mouths to the dub after the render. Paid and remote, so the
/// row says what it costs and is disabled until a Sync Labs key is saved.
struct LipSyncToggleRows: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("settings.selectedTab") private var settingsTab = "profile"
    @AppStorage(AISettingsPane.storageKey) private var aiPane = AISettingsPane.routing.rawValue
    @Binding var isOn: Bool
    @State private var hasKey: Bool?
    @State private var probe = 0

    private var model: LipSync.Model { LipSync.model(store.settings.ai.lipSync?.model) }

    private var caption: String {
        if hasKey == false { return "Needs a Sync Labs key. Lip sync is a paid service from sync.so." }
        return isOn
            ? "Before the render each dubbed clip of the recording goes to Sync Labs, which redraws the mouths to the dub: \(LipSync.rateLabel(model)) with \(model.label). A clip is paid for once: later reels reuse it while the clip and its lines stay the same. If it fails, you keep the reel without it."
            : "Redraws the speakers' mouths to match the dub. Paid: \(LipSync.rateLabel(model)) of reel with \(model.label)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsRow("Lip sync") {
                Toggle("Lip sync", isOn: Binding(get: { isOn && hasKey != false }, set: { isOn = $0 }))
                    .labelsHidden()
                    .disabled(hasKey == false)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(caption)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if hasKey == false {
                    Button("Open Settings…") {
                        settingsTab = "ai"
                        aiPane = AISettingsPane.lipSync.rawValue
                        openSettings()
                    }
                    .controlSize(.small).lineLimit(1).fixedSize()
                }
            }
        }
        // Shown off without a key, so stored off: a key added later must not
        // switch a paid step back on by itself. Also when a preset turns it
        // on while there is no key.
        .onChange(of: hasKey) { storeOffWithoutKey() }
        .onChange(of: isOn) { storeOffWithoutKey() }
        // Checked again when the app comes forward: the key is added in Settings.
        .task(id: scenePhase) { await readKey() }
        .onReceive(NotificationCenter.default.publisher(for: LipSyncService.keyChanged)) { _ in
            Task { await readKey() }
        }
    }

    private func storeOffWithoutKey() {
        if hasKey == false, isOn { isOn = false }
    }

    /// Only the newest read counts, and a keychain that could not be read
    /// (nil) is not "no key": the choice is kept.
    private func readKey() async {
        probe += 1
        let mine = probe
        let state = await Task.detached { LipSyncService.keyState }.value
        guard mine == probe else { return }
        hasKey = state
    }
}
