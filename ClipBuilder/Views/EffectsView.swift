import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

/// Assets > Effects: every transition the Builder and AI Wizard can use,
/// grouped by family, with a looping sample of each rendered through the
/// real pipeline (two cards joined by the effect) so the names finally
/// have a picture. Samples render once per sample set and cache under
/// assets/effects. The bottom bar plays/pauses everything, sets playback
/// speed, and swaps the test cards for stills from videos of your choice.
struct EffectsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(WizardDefaults.limitTransitionsKey) private var aiTransitionsLimited = false
    @AppStorage(WizardDefaults.allowedTransitionsKey) private var aiTransitionsRaw = ""
    @State private var previews: [String: URL] = [:]
    @State private var rendering: Set<String> = []
    @State private var failures: [String: String] = [:]
    @State private var renderAllTask: Task<Void, Never>?
    @State private var xfadeDuration = SettingsStore.loadSettings().transitions.xfadeDuration

    /// Everything plays unless paused here; a card click flips just that
    /// card, Play All / Pause All reset every override.
    @State private var playingAll = false
    @State private var playOverrides: [String: Bool] = [:]
    @AppStorage("effects.playbackSpeed") private var playbackSpeed = 1.0
    @State private var samples = EffectSampleSet.saved
    @State private var pickingSample: SampleSlot?

    private enum SampleSlot: String, Identifiable {
        case a, b
        var id: String { rawValue }
    }

    private var effects: [TransitionEffect] { TransitionCatalog.all }

    private var aiTransitionAvailability: Set<String> {
        // Read through the AppStorage values so the view re-renders on change.
        _ = (aiTransitionsLimited, aiTransitionsRaw)
        return WizardDefaults.transitionAvailability(all: effects.map(\.name))
    }

    private func aiTransitionBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { aiTransitionAvailability.contains(name) },
            set: { enabled in
                var selected = aiTransitionAvailability
                if enabled { selected.insert(name) } else { selected.remove(name) }
                setAITransitionAvailability(selected)
            }
        )
    }

    private func setAITransitionAvailability(_ selected: Set<String>) {
        WizardDefaults.setTransitionAvailability(selected, all: effects.map(\.name))
        aiTransitionsLimited = UserDefaults.standard.bool(forKey: WizardDefaults.limitTransitionsKey)
        aiTransitionsRaw = UserDefaults.standard.string(forKey: WizardDefaults.allowedTransitionsKey) ?? ""
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.spaceXL) {
                if !previews.isEmpty {
                    DisclosureGroup("Preview controls") {
                        playbackBar
                            .padding(.top, Theme.spaceS)
                    }
                }
                ForEach(TransitionEffect.Category.allCases, id: \.self) { category in
                    categorySection(category)
                }
            }
            .padding()
        }
        .navigationTitle("Transitions")
        .navigationSubtitle("\(effects.count) transitions")
        .toolbar {
            ToolbarItemGroup {
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Render All Previews", systemImage: "play.rectangle.on.rectangle") {
                        renderAll()
                    }
                    .disabled(renderAllTask != nil)
                    Menu("AI Palette", systemImage: "wand.and.stars") {
                        Button("Let AI Choose Any Effect") {
                            setAITransitionAvailability(Set(effects.map(\.name)))
                        }
                        Button("Hard Cuts Only") {
                            setAITransitionAvailability([])
                        }
                        Divider()
                        ForEach(TransitionEffect.Category.allCases.filter { $0 != .cut }, id: \.self) { category in
                            let members = effects.filter { $0.category == category }
                            Menu(category.title) {
                                ForEach(members) { effect in
                                    Toggle(effect.title, isOn: aiTransitionBinding(for: effect.name))
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Show in Finder", systemImage: "folder") {
                        try? FileManager.default.createDirectory(at: EffectPreviewRenderer.directory,
                                                                 withIntermediateDirectories: true)
                        NSWorkspace.shared.open(EffectPreviewRenderer.directory)
                    }
                }
                .help("Render previews, manage AI availability, or reveal cached files")
            }
        }
        .fileImporter(isPresented: Binding(get: { pickingSample != nil },
                                           set: { if !$0 { pickingSample = nil } }),
                      allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            guard let slot = pickingSample, case .success(let url) = result else { return }
            switch slot {
            case .a: samples.videoA = url
            case .b: samples.videoB = url
            }
            samplesChanged()
        }
        .onAppear { loadCached() }
        .onDisappear { renderAllTask?.cancel() }
    }

    @ViewBuilder
    private func categorySection(_ category: TransitionEffect.Category) -> some View {
        let members = effects.filter { $0.category == category }
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                Text(category.title)
                    .font(.title3.bold())
                Text(category.blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180),
                                             spacing: Theme.spaceM, alignment: .top)],
                          spacing: Theme.spaceM) {
                    ForEach(members) { effect in
                        card(effect)
                    }
                }
            }
        }
    }

    // MARK: - Cards

    private func isPlaying(_ effect: TransitionEffect) -> Bool {
        playOverrides[effect.name] ?? playingAll
    }

    private func card(_ effect: TransitionEffect) -> some View {
        let playing = isPlaying(effect)
        let animating = playing && !reduceMotion
        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.black)
                if let url = previews[effect.name] {
                    Button {
                        playOverrides[effect.name] = !playing
                    } label: {
                        LoopingVideoView(url: url, isPlaying: animating, rate: Float(playbackSpeed))
                            .overlay {
                                if !animating {
                                    Image(systemName: "play.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white.opacity(0.85))
                                        .shadow(radius: 3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(reduceMotion)
                    .accessibilityLabel(animating ? "Pause \(effect.title) preview" : "Play \(effect.title) preview")
                    .help(reduceMotion
                          ? "Preview animation is disabled because Reduce Motion is on"
                          : (animating ? "Pause preview" : "Play preview"))
                } else if rendering.contains(effect.name) {
                    ProgressView()
                        .controlSize(.small)
                } else if let failure = failures[effect.name] {
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(failure)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                        Button("Retry") { render(effect) }
                            .controlSize(.mini)
                    }
                    .padding(6)
                } else {
                    Button {
                        render(effect)
                    } label: {
                        Label("Render Preview", systemImage: "play.circle")
                    }
                    .controlSize(.small)
                    .help("Render a sample of this effect (two cards joined by it)")
                }
            }
            .aspectRatio(9 / 16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))

            HStack(alignment: .firstTextBaseline) {
                Text(effect.title)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(effect.name)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Text(effect.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let overlap = effect.consumedOverlap(xfadeDuration: xfadeDuration)
            if overlap > 0 {
                Text(String(format: "Consumes %.2fs of the timeline at the cut", overlap))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.cardPadding)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    // MARK: - Bottom bar

    private var playbackBar: some View {
        HStack(spacing: Theme.spaceM) {
            Button("Play All", systemImage: "play.fill") {
                playingAll = true
                playOverrides = [:]
            }
            .disabled(reduceMotion)
            .help("Play every preview")
            Button("Pause All", systemImage: "pause.fill") {
                playingAll = false
                playOverrides = [:]
            }
            .help("Pause every preview")

            Divider().frame(height: 20)

            HStack(spacing: 6) {
                Text("Speed")
                    .font(.callout)
                Slider(value: $playbackSpeed, in: 0.25...2, step: 0.25)
                    .frame(width: 140)
                    .help("How fast the previews play — slow the transitions down to study them")
                Text(playbackSpeed.formatted(.number.precision(.fractionLength(0...2))) + "×")
                    .font(.callout.monospacedDigit())
                    .frame(width: 44, alignment: .leading)
            }

            Divider().frame(height: 20)

            sampleButton(slot: .a, url: samples.videoA, title: "Video A")
            sampleButton(slot: .b, url: samples.videoB, title: "Video B")
            Button("Reset", systemImage: "arrow.counterclockwise") {
                samples = EffectSampleSet()
                playbackSpeed = 1
                playingAll = true
                playOverrides = [:]
                samplesChanged()
            }
            .help("Back to the built-in test cards at normal speed")

            Spacer()
            Text(samples.isDefault
                 ? "Previews use two test cards — pick a Video A and B to see the effects on your own footage."
                 : "Previews use a still from each chosen video.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.spaceL)
        .padding(.vertical, Theme.spaceS)
    }

    private func sampleButton(slot: SampleSlot, url: URL?, title: String) -> some View {
        Button {
            pickingSample = slot
        } label: {
            HStack(spacing: 6) {
                if let url {
                    VideoThumbnail(url: url, time: 0, cornerRadius: 3)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "film")
                }
                Text(url?.lastPathComponent ?? title)
                    .lineLimit(1)
                    .frame(maxWidth: 140)
            }
        }
        .help(url.map { "\(title): \($0.lastPathComponent) — click to pick another video" }
              ?? "Pick a video whose still frame plays the \(title == "Video A" ? "outgoing" : "incoming") side of every preview")
    }

    // MARK: - Rendering

    private func loadCached() {
        previews = [:]
        failures = [:]
        for effect in effects where EffectPreviewRenderer.hasPreview(for: effect, samples: samples) {
            previews[effect.name] = EffectPreviewRenderer.previewURL(for: effect, samples: samples)
        }
        xfadeDuration = SettingsStore.loadSettings().transitions.xfadeDuration
    }

    /// New sample stills: every visible card re-renders against them.
    private func samplesChanged() {
        samples.save()
        renderAllTask?.cancel()
        renderAllTask = nil
        loadCached()
    }

    private func render(_ effect: TransitionEffect) {
        guard !rendering.contains(effect.name), previews[effect.name] == nil else { return }
        rendering.insert(effect.name)
        failures[effect.name] = nil
        let samples = samples
        Task {
            do {
                let url = try await EffectPreviewRenderer.preview(for: effect, samples: samples)
                // A sample change mid-render makes this result stale.
                if samples == self.samples { previews[effect.name] = url }
            } catch {
                failures[effect.name] = error.userMessage
            }
            rendering.remove(effect.name)
        }
    }

    private func renderAll() {
        let samples = samples
        renderAllTask = Task {
            for effect in effects where previews[effect.name] == nil && !Task.isCancelled {
                rendering.insert(effect.name)
                do {
                    let url = try await EffectPreviewRenderer.preview(for: effect, samples: samples)
                    if samples == self.samples { previews[effect.name] = url }
                } catch {
                    failures[effect.name] = error.userMessage
                }
                rendering.remove(effect.name)
            }
            renderAllTask = nil
        }
    }
}

/// A muted, looping, control-free player for short sample clips, with
/// play/pause and playback rate driven from SwiftUI state.
struct LoopingVideoView: NSViewRepresentable {
    let url: URL
    var isPlaying = true
    var rate: Float = 1

    final class LoopingPlayerView: NSView {
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        var url: URL?
        private let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            playerLayer.player = player
            player.isMuted = true
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }

        func load(_ url: URL) {
            guard self.url != url else { return }
            self.url = url
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }

        func apply(playing: Bool, rate: Float) {
            if playing {
                if player.rate != rate { player.rate = rate }
            } else {
                if player.rate != 0 { player.pause() }
                // A paused player that never played shows nothing — seek so
                // the poster frame renders.
                if let item = player.currentItem, item.currentTime() == .zero {
                    item.seek(to: .zero, completionHandler: nil)
                }
            }
        }
    }

    func makeNSView(context: Context) -> LoopingPlayerView {
        let view = LoopingPlayerView(frame: .zero)
        view.load(url)
        view.apply(playing: isPlaying, rate: rate)
        return view
    }

    func updateNSView(_ nsView: LoopingPlayerView, context: Context) {
        nsView.load(url)
        nsView.apply(playing: isPlaying, rate: rate)
    }

    static func dismantleNSView(_ nsView: LoopingPlayerView, coordinator: ()) {
        nsView.player.pause()
        nsView.looper = nil
    }
}
