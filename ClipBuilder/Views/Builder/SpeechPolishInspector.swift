import AVFoundation
import SwiftUI

/// Builder inspector section for the export's audio finishing pass, with an
/// Original / Polished audition of the slice at the playhead.
struct SpeechPolishInspector: View {
    @Environment(AppStore.self) private var store
    @State private var player = AVPlayer()
    @State private var audition: AppStore.SpeechPolishAudition?
    @State private var listeningToPolished = true
    @State private var isPlaying = false
    @State private var auditionTask: Task<Void, Never>?

    private var settings: SpeechPolishSettings {
        store.builder.document.renderSettings.speechPolish ?? SpeechPolishSettings(enabled: false)
    }

    var body: some View {
        InspectorSection("Speech Polish") {
            Toggle("Polish speech on export", isOn: Binding(
                get: { settings.enabled },
                set: { update(enabled: $0) }))
                .lineLimit(1)
                .help("High-pass, noise reduction and loudness to \(Int(SpeechPolish.targetLoudness)) LUFS on the final mix. Leave off for fight reels to keep crowd and cage sound.")
            if settings.enabled {
                ViewThatFits(in: .horizontal) {
                    strengthPicker.pickerStyle(.segmented)
                    strengthPicker.pickerStyle(.menu)
                }
            }
            auditionControls
            Text("Applies to exports and exact previews.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onDisappear { stopAudition() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            if (note.object as? AVPlayerItem) === player.currentItem { isPlaying = false }
        }
    }

    private var strengthPicker: some View {
        Picker("Strength", selection: Binding(
            get: { settings.strength },
            set: { update(strength: $0) })) {
            ForEach(SpeechPolishSettings.Strength.allCases) { strength in
                Text(strength.label).lineLimit(1).tag(strength)
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var auditionControls: some View {
        if auditionTask != nil {
            HStack(spacing: Theme.spaceS) {
                ProgressView().controlSize(.small)
                Text("Rendering audition…").lineLimit(1).fixedSize()
                    .font(.caption).foregroundStyle(.secondary)
                Button("Stop") { cancelAuditionRender() }
                    .lineLimit(1).fixedSize()
            }
        } else if audition != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceS) { listeningControls }
                VStack(alignment: .leading, spacing: Theme.spaceS) { listeningControls }
            }
        } else {
            Button {
                startAudition()
            } label: {
                Label("Audition \(Int(AppStore.speechPolishAuditionSeconds)) s at playhead", systemImage: "waveform.badge.magnifyingglass")
                    .lineLimit(1)
            }
            .fixedSize()
            .disabled(store.builder.document.videoTrack.isEmpty || store.isBuilderRendering || store.isBuilderPreviewRendering)
        }
    }

    @ViewBuilder private var listeningControls: some View {
        Picker("Listen to", selection: Binding(
            get: { listeningToPolished },
            set: { swap(toPolished: $0) })) {
            Text("Original").lineLimit(1).tag(false)
            Text("Polished").lineLimit(1).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Button {
            togglePlayback()
        } label: {
            Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                .lineLimit(1)
        }
        .fixedSize()
        Button("Done") { stopAudition() }
            .lineLimit(1).fixedSize()
    }

    // MARK: - Settings

    private func update(enabled: Bool? = nil, strength: SpeechPolishSettings.Strength? = nil) {
        var render = store.builder.document.renderSettings
        var polish = render.speechPolish ?? SpeechPolishSettings(enabled: false)
        if let enabled { polish.enabled = enabled }
        if let strength {
            polish.strength = strength
            // The polished half was made at the old strength.
            stopAudition()
        }
        render.speechPolish = polish
        store.builder.setRenderSettings(render)
    }

    // MARK: - Audition

    private func startAudition() {
        stopAudition()
        var polish = settings
        polish.enabled = true
        auditionTask = Task {
            let result = await store.renderSpeechPolishAudition(settings: polish)
            // A cancelled task no longer owns `auditionTask` or the files.
            guard !Task.isCancelled else {
                AppStore.discardSpeechPolishAudition(result)
                return
            }
            auditionTask = nil
            guard let result else { return }
            audition = result
            listeningToPolished = true
            player.replaceCurrentItem(with: AVPlayerItem(url: result.polished))
            player.play()
            isPlaying = true
        }
    }

    private func cancelAuditionRender() {
        auditionTask?.cancel()
        auditionTask = nil
    }

    /// Same player, same position: only the sound changes.
    private func swap(toPolished: Bool) {
        guard let audition, toPolished != listeningToPolished else { return }
        listeningToPolished = toPolished
        let time = player.currentTime()
        let wasPlaying = player.rate != 0
        player.replaceCurrentItem(with: AVPlayerItem(url: toPolished ? audition.polished : audition.original))
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
    }

    private func togglePlayback() {
        if player.rate != 0 {
            player.pause()
            isPlaying = false
            return
        }
        if let item = player.currentItem, item.duration.isNumeric,
           player.currentTime() >= item.duration - CMTime(seconds: 0.1, preferredTimescale: 600) {
            player.seek(to: .zero)
        }
        player.play()
        isPlaying = true
    }

    private func stopAudition() {
        cancelAuditionRender()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        AppStore.discardSpeechPolishAudition(audition)
        audition = nil
    }
}
