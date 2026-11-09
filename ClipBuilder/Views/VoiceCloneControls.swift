import SwiftUI

/// Shared visible entry point in dub review and the People detail pane.
/// The clone mapping is shared with the team through the profile document,
/// but a clone lives in one ElevenLabs account: a teammate whose key is for
/// another account sees the clone marked as such, without Re-clone or Remove,
/// which would act on the wrong account.
struct VoiceCloneControls: View {
    let store: AppStore
    let personKey: String
    let name: String
    @State private var showConsent = false
    @State private var showRemove = false
    /// Whether this Mac's ElevenLabs account holds the clone; nil until checked
    /// or when the account cannot be reached.
    @State private var inThisAccount: Bool?
    @State private var accountRevision = 0

    private var cloneID: String? { store.editingDefaults.clonedVoices?[personKey] }

    var body: some View {
        HStack(spacing: 6) {
            if cloneID != nil, inThisAccount == false {
                Label("Other account", systemImage: "person.2")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .help("A teammate cloned \(name)'s voice with a different ElevenLabs account. "
                        + "Teammates on that account dub with it; pick another voice here.")
            } else if cloneID != nil {
                Label("Cloned", systemImage: "waveform.badge.checkmark")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .help("Shared with your team")
                // Re-clone and Remove act on this account; offer them only once
                // the account is known to hold the clone, never while checking.
                if inThisAccount == true { cloneMenu }
            } else {
                Button("Clone voice…") { showConsent = true }.lineLimit(1).fixedSize()
            }
        }
        .disabled(store.isVoiceCloneBusy(personKey: personKey))
        .task(id: "\(cloneID ?? "")|\(accountRevision)") { await checkAccount() }
        .onReceive(NotificationCenter.default.publisher(for: ElevenLabsVoices.settingsChanged)) { _ in
            accountRevision += 1
        }
        .sheet(isPresented: $showConsent) {
            VoiceCloneConsentSheet(name: name) {
                store.startVoiceClone(personKey: personKey)
            }
        }
        .confirmationDialog("Remove \(name)'s cloned voice?", isPresented: $showRemove) {
            Button("Remove clone", role: .destructive) { store.removeVoiceClone(personKey: personKey) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the voice from your ElevenLabs account and clears this person's remembered voice for everyone on your team.")
        }
    }

    private var cloneMenu: some View {
        Menu {
            Button("Re-clone…") { showConsent = true }
            Button("Remove clone…", role: .destructive) { showRemove = true }
        } label: {
            Label("Clone options", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly).lineLimit(1).fixedSize()
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Clone options for \(name)")
    }

    private func checkAccount() async {
        guard let cloneID else { inThisAccount = nil; return }
        guard let voices = try? await ElevenLabsVoiceCache.shared.voices(), !Task.isCancelled else {
            inThisAccount = nil
            return
        }
        if voices.contains(where: { $0.voiceID == cloneID }) { inThisAccount = true; return }
        // A teammate's clone can arrive after this account's list was cached.
        guard let fresh = try? await ElevenLabsVoiceCache.shared.refresh(), !Task.isCancelled else {
            inThisAccount = nil
            return
        }
        inThisAccount = fresh.contains { $0.voiceID == cloneID }
    }
}
