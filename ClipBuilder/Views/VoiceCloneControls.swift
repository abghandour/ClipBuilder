import SwiftUI

/// Shared visible entry point in dub review and the People detail pane.
struct VoiceCloneControls: View {
    let store: AppStore
    let personKey: String
    let name: String
    @State private var showConsent = false
    @State private var showRemove = false

    private var hasClone: Bool { store.editingDefaults.clonedVoices?[personKey] != nil }

    var body: some View {
        HStack(spacing: 6) {
            if hasClone {
                Label("Cloned", systemImage: "waveform.badge.checkmark")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Menu {
                    Button("Re-clone…") { showConsent = true }
                    Button("Remove clone…", role: .destructive) { showRemove = true }
                } label: {
                    Label("Clone options", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly).lineLimit(1).fixedSize()
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Clone options for \(name)")
            } else {
                Button("Clone voice…") { showConsent = true }.lineLimit(1).fixedSize()
            }
        }
        .disabled(store.isVoiceCloneBusy(personKey: personKey))
        .sheet(isPresented: $showConsent) {
            VoiceCloneConsentSheet(name: name) {
                store.startVoiceClone(personKey: personKey)
            }
        }
        .confirmationDialog("Remove \(name)'s cloned voice?", isPresented: $showRemove) {
            Button("Remove clone", role: .destructive) { store.removeVoiceClone(personKey: personKey) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the voice from your ElevenLabs account and clears this person's remembered voice.")
        }
    }
}
