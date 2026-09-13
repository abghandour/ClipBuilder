import SwiftUI
import UniformTypeIdentifiers

/// Resource browser for looks, using rendered samples from the export pipeline.
struct LooksView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("looks.playbackSpeed") private var playbackSpeed = 1.0
    @State private var samples = EffectSampleSet.saved
    @State private var availableIDs: Set<String>?
    @State private var previews: [String: URL] = [:]
    @State private var failures: [String: String] = [:]
    @State private var rendering: String?
    @State private var renderTask: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var playingAll = false
    @State private var playOverrides: [String: Bool] = [:]
    @State private var pickingSample = false
    @State private var sampleError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.spaceXL) {
                playbackBar
                Text(samples.videoA.map { "Sample: \($0.lastPathComponent) · shared with Transitions Video A" }
                     ?? "Samples use the built-in test card. Choose a video to compare looks on your footage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(EffectControls.groups, id: \.self) { group in
                    VStack(alignment: .leading, spacing: Theme.spaceS) {
                        Text(group.capitalized).font(.title3.bold())
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180),
                                                     spacing: Theme.spaceM, alignment: .top)],
                                  spacing: Theme.spaceM) {
                            ForEach(EffectCatalog.presets.filter { $0.group == group }, id: \.id) { preset in
                                card(preset)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .screenTitle("Looks", subtitle: "\(EffectCatalog.presets.count) presets")
        .toolbar {
            ToolbarItemGroup {
                Button("Render All Previews", systemImage: "play.rectangle.on.rectangle") {
                    render(EffectCatalog.ids)
                }
                .disabled(renderTask != nil || availableIDs == nil || store.database == nil)
                .help("Render a sample of every available look through the final render pipeline")
                Button("Change sample…", systemImage: "film") { pickingSample = true }
                    .help("Choose the video used for every look and Transitions Video A")
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
            availableIDs = await EffectControls.availablePresetIDs()
            guard !Task.isCancelled else { return }
            // Like Transitions: show what is cached, render on demand. A cold
            // cache would otherwise start 27 full-pipeline renders on first open.
            loadCached()
        }
        .onDisappear { cancelRendering() }
    }

    private var playbackBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.spaceM) {
                playbackButtons
                speedControl
                resetButton
            }
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                HStack(spacing: Theme.spaceM) {
                    playbackButtons
                    resetButton
                }
                speedControl
            }
        }
        .controlSize(.small)
    }

    private var playbackButtons: some View {
        Group {
            Button("Play All", systemImage: "play.fill") {
                playingAll = true
                playOverrides = [:]
            }
            .disabled(reduceMotion)
            .help(reduceMotion ? "Preview animation is disabled because Reduce Motion is on" : "Play every look sample")
            Button("Pause All", systemImage: "pause.fill") {
                playingAll = false
                playOverrides = [:]
            }
            .help("Pause every look sample")
        }
    }

    private var speedControl: some View {
        HStack(spacing: Theme.spaceS) {
            Text("Speed").font(.callout)
            Slider(value: $playbackSpeed, in: 0.25...2, step: 0.25)
                .frame(width: 140)
                .accessibilityLabel("Preview playback speed")
                .help("Preview speed: 0.25×…2×. This does not change the look or timeline.")
            Text(playbackSpeed.formatted(.number.precision(.fractionLength(0...2))) + "×")
                .font(.callout.monospacedDigit())
                .frame(width: 44, alignment: .leading)
        }
    }

    private var resetButton: some View {
        Button("Reset", systemImage: "arrow.counterclockwise") {
            playbackSpeed = 1
            playingAll = false
            playOverrides = [:]
            changeSample(to: nil)
        }
        .help("Use the built-in test card at normal speed; also resets Transitions Video A")
    }

    private func card(_ preset: EffectCatalog.Preset) -> some View {
        let available = availableIDs?.contains(preset.id) == true
        let playing = (playOverrides[preset.id] ?? playingAll) && !reduceMotion
        return VStack(alignment: .leading, spacing: Theme.spaceS) {
            ZStack {
                Rectangle().fill(.black)
                if let url = previews[preset.id], available {
                    Button {
                        playOverrides[preset.id] = !playing
                    } label: {
                        LoopingVideoView(url: url, isPlaying: playing, rate: Float(playbackSpeed))
                            .id(generation)
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
                            .disabled(renderTask != nil || store.database == nil)
                            .help(store.database == nil ? "Open a profile to render look samples"
                                  : "Render this look through the final render pipeline")
                    }
                    .padding(Theme.spaceS)
                }
            }
            .aspectRatio(9.0 / 16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
            Text(preset.name).font(.callout.weight(.semibold))
            Text("\(preset.group.capitalized) · \(availableIDs == nil ? "Checking availability" : available ? "Available" : "Unavailable")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.cardPadding)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    private func cancelRendering() {
        generation = UUID()
        renderTask?.cancel()
        renderTask = nil
        rendering = nil
    }

    private func changeSample(to url: URL?) {
        cancelRendering()
        // Preserve Video B if it was changed in another window.
        samples = .saved
        samples.videoA = url
        samples.save()
        loadCached()
    }

    private func loadCached() {
        previews = [:]
        failures = [:]
        for id in EffectCatalog.ids where LookSamples.hasPreview(for: id, video: samples.videoA) {
            previews[id] = LookSamples.previewURL(for: id)
        }
    }

    private func render(_ ids: [String]) {
        guard renderTask == nil, let database = store.database, let availableIDs else { return }
        let pending = ids.filter { availableIDs.contains($0) && previews[$0] == nil }
        guard !pending.isEmpty else { return }
        let current = generation
        let video = samples.videoA
        let profile = store.activeProfile
        renderTask = Task {
            defer {
                if current == generation {
                    rendering = nil
                    renderTask = nil
                }
            }
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
