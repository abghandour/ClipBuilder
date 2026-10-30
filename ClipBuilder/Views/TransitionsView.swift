import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

/// Resource browser with one selected transition, rendered through the real pipeline.
struct TransitionsView: View {
    @Environment(\.workspacePageVisible) private var pageVisible
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(WizardDefaults.limitTransitionsKey) private var aiTransitionsLimited = false
    @AppStorage(WizardDefaults.allowedTransitionsKey) private var aiTransitionsRaw = ""
    @AppStorage(EffectSamplePicker.Page.transitions.defaultsKey) private var selectedTab = "cut"
    @State private var previews: [String: URL] = [:]
    @State private var needsCacheLoad = true
    @State private var rendering: Set<String> = []
    @State private var failures: [String: String] = [:]
    @State private var renderAllTask: Task<Void, Never>?
    @State private var generation = UUID()
    private var xfadeDuration: Double { store.editingDefaults.transitions.xfadeDuration }

    @State private var isPlaying = true
    @AppStorage(EffectSamplePicker.Page.transitions.itemDefaultsKey) private var rememberedItem = ""
    @AppStorage("effects.playbackSpeed") private var playbackSpeed = 1.0
    @State private var samples = EffectSampleSet.saved
    @State private var pickingSample: EffectSamplePicker.Slot = .videoA
    @State private var showingSampleImporter = false
    @State private var sampleError: String?

    private var effects: [TransitionEffect] { TransitionCatalog.all }

    private var tab: String { EffectSamplePicker.Page.transitions.selectedTab(selectedTab) }
    private var selectedItem: String {
        EffectSamplePicker.Page.transitions.selectedItem(rememberedItem, for: tab) ?? ""
    }
    private var selectedEffect: TransitionEffect? { effects.first { $0.name == selectedItem } }
    private var subtitle: String {
        guard let selectedEffect else { return "No transitions" }
        return "\(selectedEffect.title) · \(selectedEffect.category.title)"
    }

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
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            sampleRow
            EffectBrowserTabs(page: .transitions, selection: $selectedTab)
            EffectBrowserItems(page: .transitions, tab: tab, selection: $rememberedItem)
            playbackBar
            if let effect = selectedEffect {
                EffectBrowserPreview {
                    preview(effect)
                } details: {
                    details(effect)
                }
            }
        }
        .padding()
        .screenTitle("Transitions", subtitle: subtitle)
        .toolbar {
            if pageVisible {
                ToolbarItemGroup {
                    Button("Render All Previews", systemImage: "play.rectangle.on.rectangle") {
                        renderAll()
                    }
                    .disabled(renderAllTask != nil)
                    .help("Render a sample of every transition through the real pipeline")
                    .lineLimit(1).fixedSize()
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
                    .help("Choose which transitions the AI Wizard may use")
                    .lineLimit(1).fixedSize()
                    Button("Show in Finder", systemImage: "folder") {
                        try? FileManager.default.createDirectory(at: EffectPreviewRenderer.directory,
                                                                 withIntermediateDirectories: true)
                        NSWorkspace.shared.open(EffectPreviewRenderer.directory)
                    }
                    .help("Reveal the rendered preview files in Finder")
                    .lineLimit(1).fixedSize()
                }
            }
        }
        .fileImporter(isPresented: $showingSampleImporter,
                      allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            switch result {
            case .success(let url): changeSample(to: url, slot: pickingSample)
            case .failure(let error): sampleError = error.localizedDescription
            }
        }
        .alert("Could not change sample", isPresented: Binding(
            get: { sampleError != nil }, set: { if !$0 { sampleError = nil } })) {
            Button("OK") { sampleError = nil }
        } message: {
            Text(sampleError ?? "")
        }
        .onAppear {
            samples = .saved
            rememberedItem = selectedItem
            isPlaying = true
            renderSelected()
        }
        .onChange(of: selectedTab) { _, _ in
            rememberedItem = selectedItem
        }
        .onChange(of: selectedItem) { _, _ in
            isPlaying = true
            renderSelected()
        }
        .onChange(of: store.database == nil) { _, _ in
            cancelRendering()
            renderSelected()
        }
        .onChange(of: store.editingDefaults.transitions) { _, _ in
            cancelRendering()
            renderSelected()
        }
        .onDisappear { cancelRendering() }
    }

    private func preview(_ effect: TransitionEffect) -> some View {
        let animating = isPlaying && !reduceMotion && pageVisible
        return ZStack {
            Rectangle().fill(.black)
            if let url = previews[effect.name] {
                Button {
                    isPlaying.toggle()
                } label: {
                    LoopingVideoView(url: url, isPlaying: animating, rate: Float(playbackSpeed))
                        .id(effect.name + generation.uuidString)
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
                    .accessibilityLabel("Preparing \(effect.title) preview")
            } else if let failure = failures[effect.name] {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Button("Retry") { render(effect) }
                        .controlSize(.small)
                        .lineLimit(1).fixedSize()
                        .disabled(renderAllTask != nil || store.database == nil)
                }
                .padding(6)
            } else {
                Button {
                    render(effect)
                } label: {
                    Label("Render Preview", systemImage: "play.circle")
                }
                .controlSize(.small)
                .lineLimit(1).fixedSize()
                .disabled(renderAllTask != nil || store.database == nil)
                .help("Render a sample of this effect (two cards joined by it)")
            }
        }
    }

    private func details(_ effect: TransitionEffect) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            Text(subtitle).font(.headline).lineLimit(1)
            Button(isPlaying && !reduceMotion ? "Pause" : "Play",
                   systemImage: isPlaying && !reduceMotion ? "pause.fill" : "play.fill") {
                isPlaying.toggle()
            }
            .disabled(previews[effect.name] == nil || reduceMotion)
            .accessibilityLabel("\(isPlaying && !reduceMotion ? "Pause" : "Play") \(effect.title) preview")
            .lineLimit(1).fixedSize()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceM) {
                    aiToggle(effect)
                    aiSummary
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    aiToggle(effect)
                    aiSummary
                }
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
    }

    private func aiToggle(_ effect: TransitionEffect) -> some View {
        Toggle("Available to AI", isOn: aiTransitionBinding(for: effect.name))
            .lineLimit(1).fixedSize()
            .help("Limit AI to the transitions enabled here or in AI Palette")
    }

    private var aiSummary: some View {
        Text(!aiTransitionsLimited ? "AI: all transitions"
             : aiTransitionAvailability.isEmpty ? "AI: hard cuts only"
             : "AI: \(aiTransitionAvailability.count) of \(effects.count) transitions")
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
    }

    // MARK: - Samples and playback

    private var sampleRow: some View {
        let sources = EffectSamplePicker.sources(from: store.videos)
        return VStack(alignment: .leading, spacing: Theme.spaceS) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceM) {
                    sampleMenu(slot: .videoA, title: "Video A", url: samples.videoA, sources: sources)
                    sampleMenu(slot: .videoB, title: "Video B", url: samples.videoB, sources: sources)
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    sampleMenu(slot: .videoA, title: "Video A", url: samples.videoA, sources: sources)
                    sampleMenu(slot: .videoB, title: "Video B", url: samples.videoB, sources: sources)
                }
            }
            Text("Previews use a still from each video. Video A is shared with Effects.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sampleMenu(slot: EffectSamplePicker.Slot, title: String, url: URL?,
                            sources: [EffectSamplePicker.Source]) -> some View {
        EffectSampleMenu(title: title, accessibilityTitle: title, sources: sources,
                         projectHasSources: !store.videos.isEmpty, selectedURL: url,
                         select: { changeSample(to: $0, slot: slot) }, otherFile: {
                             pickingSample = slot
                             showingSampleImporter = true
                         })
    }

    private var playbackBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.spaceM) {
                speedControl
                resetButton
            }
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                speedControl
                resetButton
            }
        }
        .controlSize(.small)
    }

    private var speedControl: some View {
        HStack(spacing: Theme.spaceS) {
            Text("Speed").font(.callout)
            Slider(value: $playbackSpeed, in: 0.25...2, step: 0.25)
                .frame(width: 140)
                .accessibilityLabel("Preview playback speed")
                .help("How fast the previews play — slow the transitions down to study them")
            Text(playbackSpeed.formatted(.number.precision(.fractionLength(0...2))) + "×")
                .font(.callout.monospacedDigit())
                .frame(width: 44, alignment: .leading)
        }
        .lineLimit(1).fixedSize()
    }

    private var resetButton: some View {
        Button("Reset", systemImage: "arrow.counterclockwise") {
            samples = EffectSampleSet()
            playbackSpeed = 1
            isPlaying = true
            samplesChanged()
        }
        .help("Back to the built-in test cards at normal speed")
        .lineLimit(1).fixedSize()
    }

    // MARK: - Rendering

    private func loadCached() async {
        let effects = effects
        let samples = samples
        let transitions = store.editingDefaults.transitions
        let current = generation
        let cached = await Task.detached(priority: .userInitiated) {
            var urls: [String: URL] = [:]
            for effect in effects where EffectPreviewRenderer.hasPreview(for: effect, samples: samples, transitions: transitions) {
                urls[effect.name] = EffectPreviewRenderer.previewURL(for: effect, samples: samples, transitions: transitions)
            }
            return urls
        }.value
        guard !Task.isCancelled, current == generation else { return }
        previews = cached
        needsCacheLoad = false
    }

    private func changeSample(to url: URL?, slot: EffectSamplePicker.Slot) {
        samples = EffectSamplePicker.selecting(url, for: slot, in: .saved)
        samplesChanged()
    }

    /// New sample stills invalidate old work; other items render lazily when selected.
    private func samplesChanged() {
        samples.save()
        cancelRendering()
        isPlaying = true
        renderSelected()
    }

    private func cancelRendering() {
        generation = UUID()
        needsCacheLoad = true
        previews = [:]
        failures = [:]
        renderAllTask?.cancel()
        renderAllTask = nil
        rendering = []
    }

    private func renderSelected() {
        guard store.database != nil, let effect = selectedEffect,
              failures[effect.name] == nil, previews[effect.name] == nil else { return }
        render(effect)
    }

    private func render(_ effect: TransitionEffect) {
        render([effect])
    }

    private func renderAll() {
        render(effects)
    }

    private func render(_ requested: [TransitionEffect]) {
        guard renderAllTask == nil else { return }
        let samples = samples
        let transitions = store.editingDefaults.transitions
        let current = generation
        renderAllTask = Task {
            defer {
                if current == generation {
                    renderAllTask = nil
                    // Service the latest selection if it changed during rendering.
                    renderSelected()
                }
            }
            if needsCacheLoad { await loadCached() }
            guard !Task.isCancelled, current == generation else { return }
            let pending = requested.filter { previews[$0.name] == nil }
            for effect in pending {
                guard !Task.isCancelled, current == generation else { return }
                rendering.insert(effect.name)
                failures[effect.name] = nil
                do {
                    let url = try await EffectPreviewRenderer.preview(for: effect, samples: samples, transitions: transitions)
                    guard !Task.isCancelled, current == generation else { return }
                    previews[effect.name] = url
                } catch {
                    guard !Task.isCancelled, current == generation else { return }
                    failures[effect.name] = error.userMessage
                }
                rendering.remove(effect.name)
            }
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
