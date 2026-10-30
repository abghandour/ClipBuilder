import SwiftUI
import UniformTypeIdentifiers

/// Resource browser for looks, using rendered samples from the export pipeline.
struct LooksView: View {
    @Environment(\.workspacePageVisible) private var pageVisible
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("looks.playbackSpeed") private var playbackSpeed = 1.0
    @AppStorage(EffectSamplePicker.Page.looks.defaultsKey) private var selectedTab = "looks"
    @AppStorage(EffectSamplePicker.Page.looks.itemDefaultsKey) private var rememberedItem = ""
    @State private var samples = EffectSampleSet.saved
    @State private var availableIDs: Set<String>?
    @State private var previews: [String: URL] = [:]
    @State private var needsCacheLoad = true
    @State private var failures: [String: String] = [:]
    @State private var rendering: String?
    @State private var renderTask: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var isPlaying = true
    @State private var pickingSample = false
    @State private var sampleError: String?

    private var tab: String { EffectSamplePicker.Page.looks.selectedTab(selectedTab) }
    private var selectedItem: String {
        EffectSamplePicker.Page.looks.selectedItem(rememberedItem, for: tab) ?? ""
    }
    private var preset: EffectCatalog.Preset? { EffectCatalog.presets.first { $0.id == selectedItem } }
    private var subtitle: String { "\(preset?.name ?? "No effects") · \(tab == "looks" ? "Effects" : tab.capitalized)" }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                EffectSampleMenu(title: "Sample", accessibilityTitle: "Sample video",
                                 sources: EffectSamplePicker.sources(from: store.videos),
                                 projectHasSources: !store.videos.isEmpty, selectedURL: samples.videoA,
                                 select: changeSample, otherFile: { pickingSample = true })
                Text("Shared with Transitions Video A")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            }
            EffectBrowserTabs(page: .looks, selection: $selectedTab)
            EffectBrowserItems(page: .looks, tab: tab, selection: $rememberedItem)
            playbackBar
            if let preset {
                EffectBrowserPreview {
                    preview(preset)
                } details: {
                    VStack(alignment: .leading, spacing: Theme.spaceS) {
                        Text(subtitle).font(.headline).lineLimit(1)
                        Text(availabilityText(for: preset))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(isPlaying && !reduceMotion ? "Pause" : "Play",
                               systemImage: isPlaying && !reduceMotion ? "pause.fill" : "play.fill") {
                            isPlaying.toggle()
                        }
                        .disabled(previews[preset.id] == nil || reduceMotion)
                        .accessibilityLabel("\(isPlaying && !reduceMotion ? "Pause" : "Play") \(preset.name) preview")
                        .lineLimit(1).fixedSize()
                    }
                }
            }
        }
        .padding()
        .screenTitle("Effects", subtitle: subtitle)
        .toolbar {
            if pageVisible {
                ToolbarItemGroup {
                    Button("Render All Previews", systemImage: "play.rectangle.on.rectangle") {
                        render(EffectCatalog.ids)
                    }
                    .disabled(renderTask != nil || availableIDs == nil || store.database == nil)
                    .help("Render a sample of every available effect through the final render pipeline")
                    .lineLimit(1).fixedSize()
                    Button("Change sample…", systemImage: "film") { pickingSample = true }
                        .help("Choose the video used for every effect and Transitions Video A")
                        .lineLimit(1).fixedSize()
                }
            }
        }
        .fileImporter(isPresented: $pickingSample,
                      allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            switch result {
            case .success(let url): changeSample(to: url)
            case .failure(let error): sampleError = error.localizedDescription
            }
        }
        .alert("Could not change sample", isPresented: Binding(
            get: { sampleError != nil }, set: { if !$0 { sampleError = nil } })) {
            Button("OK") { sampleError = nil }
                .help("Dismiss this error")
        } message: {
            Text(sampleError ?? "")
        }
        .task {
            samples = .saved
            rememberedItem = selectedItem
            isPlaying = true
            availableIDs = await EffectControls.availablePresetIDs()
            guard !Task.isCancelled else { return }
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
        .onChange(of: store.activeProfile.id) { _, _ in
            cancelRendering()
            renderSelected()
        }
        .onDisappear { cancelRendering() }
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
                .help("Preview speed: 0.25×…2×. This does not change the effect or timeline.")
            Text(playbackSpeed.formatted(.number.precision(.fractionLength(0...2))) + "×")
                .font(.callout.monospacedDigit())
                .frame(width: 44, alignment: .leading)
        }
        .lineLimit(1).fixedSize()
    }

    private var resetButton: some View {
        Button("Reset", systemImage: "arrow.counterclockwise") {
            playbackSpeed = 1
            isPlaying = true
            changeSample(to: nil)
        }
        .help("Use the built-in test card at normal speed; also resets Transitions Video A")
        .lineLimit(1).fixedSize()
    }

    private func preview(_ preset: EffectCatalog.Preset) -> some View {
        let available = availableIDs?.contains(preset.id) == true
        let playing = isPlaying && !reduceMotion && pageVisible
        return ZStack {
            Rectangle().fill(.black)
            if let url = previews[preset.id], available {
                Button {
                    isPlaying.toggle()
                } label: {
                    LoopingVideoView(url: url, isPlaying: playing, rate: Float(playbackSpeed))
                        .id(preset.id + generation.uuidString)
                        .overlay {
                            if !playing {
                                Image(systemName: "play.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(reduceMotion)
                .accessibilityLabel("\(playing ? "Pause" : "Play") \(preset.name) preview")
                .help(reduceMotion ? "Preview animation is disabled because Reduce Motion is on"
                      : playing ? "Pause this sample" : "Play this sample")
            } else if rendering == preset.id || availableIDs == nil {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Preparing \(preset.name) preview")
            } else if !available {
                Label("Unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .help("The local ffmpeg lacks a required filter or the LUT is missing")
            } else {
                VStack(spacing: Theme.spaceS) {
                    if let failure = failures[preset.id] {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .help(failure)
                    }
                    Button(failures[preset.id] == nil ? "Render Preview" : "Retry",
                           systemImage: "play.circle") { render([preset.id]) }
                        .controlSize(.small)
                        .lineLimit(1).fixedSize()
                        .disabled(renderTask != nil || store.database == nil)
                        .help(store.database == nil ? "Open a profile to render effect samples"
                              : "Render this effect through the final render pipeline")
                }
                .padding(Theme.spaceS)
            }
        }
    }

    private func availabilityText(for preset: EffectCatalog.Preset) -> String {
        guard let availableIDs else { return "Checking availability" }
        return availableIDs.contains(preset.id) ? "Available" : "Unavailable — required filter or LUT is missing"
    }

    private func renderSelected() {
        guard !selectedItem.isEmpty, failures[selectedItem] == nil, previews[selectedItem] == nil,
              availableIDs?.contains(selectedItem) == true else { return }
        render([selectedItem])
    }

    private func cancelRendering() {
        generation = UUID()
        needsCacheLoad = true
        previews = [:]
        failures = [:]
        renderTask?.cancel()
        renderTask = nil
        rendering = nil
    }

    private func changeSample(to url: URL?) {
        cancelRendering()
        // Preserve Video B if it was changed in another window.
        samples = EffectSamplePicker.selecting(url, for: .look, in: .saved)
        samples.save()
        isPlaying = true
        renderSelected()
    }

    private func loadCached() async {
        let video = samples.videoA
        let current = generation
        let cached = await Task.detached(priority: .userInitiated) {
            var urls: [String: URL] = [:]
            for id in EffectCatalog.ids where LookSamples.hasPreview(for: id, video: video) {
                urls[id] = LookSamples.previewURL(for: id)
            }
            return urls
        }.value
        guard !Task.isCancelled, current == generation else { return }
        previews = cached
        needsCacheLoad = false
    }

    private func render(_ ids: [String]) {
        guard renderTask == nil, let database = store.database, let availableIDs else { return }
        let current = generation
        let video = samples.videoA
        let profile = store.activeProfile
        renderTask = Task {
            defer {
                if current == generation {
                    rendering = nil
                    renderTask = nil
                    // A selection made during a render is serviced once it finishes.
                    renderSelected()
                }
            }
            if needsCacheLoad { await loadCached() }
            guard !Task.isCancelled, current == generation else { return }
            let pending = ids.filter { availableIDs.contains($0) && previews[$0] == nil }
            for id in pending {
                guard !Task.isCancelled, current == generation else { return }
                rendering = id
                failures[id] = nil
                do {
                    let url = try await LookSamples.preview(for: id, video: video, profile: profile, database: database)
                    guard !Task.isCancelled, current == generation else { return }
                    previews[id] = url
                } catch {
                    guard !Task.isCancelled, current == generation else { return }
                    failures[id] = error.userMessage
                }
            }
        }
    }
}
