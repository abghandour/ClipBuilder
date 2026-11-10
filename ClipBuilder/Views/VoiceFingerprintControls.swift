import SwiftUI

/// The voice fingerprint row on a person's page: whether speaker mapping can
/// recognise this person by voice, which videos taught it, and a way to
/// forget one video's contribution or all of it.
struct VoiceFingerprintControls: View {
    let store: AppStore
    let personKey: String
    let name: String
    @State private var sources: [VoiceFingerprintSource] = []
    @State private var showForget = false
    @State private var forgetSource: VoiceFingerprintSource?

    var body: some View {
        HStack(spacing: 6) {
            if sources.isEmpty {
                Label("None yet", systemImage: "waveform.slash")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .help("Speaker mapping learns \(name)'s voice the first time it names them in a video. Until then it cannot recognise them by voice.")
            } else {
                Label(Self.summary(sources.count), systemImage: "waveform")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .help("Speaker mapping recognises \(name) in new videos from this. It is separate from the ElevenLabs clone, which is only used for dubbing.")
                Menu {
                    Section("Learned from") {
                        ForEach(sources) { source in
                            Button("Forget \(source.filename)…") { forgetSource = source }
                        }
                    }
                    Divider()
                    Button("Forget voice…", role: .destructive) { showForget = true }
                } label: {
                    Label("Voice fingerprint options", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly).lineLimit(1).fixedSize()
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Voice fingerprint options for \(name)")
            }
        }
        // The count alone misses one video replacing another.
        .task(id: "\(store.voiceFingerprintCounts[personKey] ?? 0)|\(store.voiceFingerprintVersion)|\(store.videoPeopleVersion)") {
            await load()
        }
        .confirmationDialog("Forget \(name)'s voice?", isPresented: $showForget) {
            Button("Forget voice", role: .destructive) { store.forgetVoiceFingerprint(personKey: personKey) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Speaker mapping will no longer recognise \(name) by voice, on this Mac and for your team. "
                + "Existing speaker maps stay as they are. The voice is learned again the next time a video with \(name) is mapped.")
        }
        .confirmationDialog("Forget what this video taught?", isPresented: Binding(
            get: { forgetSource != nil }, set: { if !$0 { forgetSource = nil } }), presenting: forgetSource) { source in
            Button("Forget this video", role: .destructive) {
                store.forgetVoiceFingerprint(personKey: personKey, videoID: source.videoID)
            }
            Button("Cancel", role: .cancel) {}
        } message: { source in
            Text("Removes \(source.filename) from \(name)'s voice fingerprint, on this Mac and for your team. "
                + "Use this when that video learned the wrong voice. Mapping its speakers again learns it again.")
        }
    }

    nonisolated static func summary(_ videos: Int) -> String {
        "Learned from \(videos) video\(videos == 1 ? "" : "s")"
    }

    private func load() async {
        guard let database = store.database else { sources = []; return }
        let loaded = (try? await database.voiceFingerprintSources(personKey: personKey)) ?? []
        if !Task.isCancelled { sources = loaded }
    }
}
