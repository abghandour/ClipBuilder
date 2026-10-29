import SwiftUI

/// A preview-only stage. Backdrop preferences are shared with the former overlay stage.
struct TextLooksStage: View {
    enum Sample {
        case captions(Binding<CaptionStyle>, Binding<String>)
        case tags(Binding<TagStyle>, Binding<String>, Binding<UUID?>)
        case overlay(Binding<OverlayComposition>, Binding<OverlayItemSelection?>)
        case named(NamedTextStyle)
    }
    let sample: Sample
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("overlays.stage.backdropMode") private var backdropMode = OverlayStageBackdrop.Mode.black.rawValue
    @AppStorage("overlays.stage.backdropColor") private var backdropColorHex = "#000000"
    @AppStorage("overlays.stage.backdropVideo") private var backdropVideoPath = ""
    @AppStorage("overlays.stage.backdropTime") private var backdropTime = 0.0
    @AppStorage(PlaybackSpeed.key) private var rate = 1.0
    @State private var started = Date.now
    @State private var playing = false
    @State private var pausedTime = 0.3
    @State private var duration = 3.0
    @State private var scrubTime = 0.0

    init(caption: Binding<CaptionStyle>, selectedState: Binding<String>) { sample = .captions(caption, selectedState) }
    init(tag: Binding<TagStyle>, selectedState: Binding<String>, selectedImage: Binding<UUID?>) {
        sample = .tags(tag, selectedState, selectedImage)
    }
    init(composition: Binding<OverlayComposition>, selection: Binding<OverlayItemSelection?>) { sample = .overlay(composition, selection) }
    init(named: NamedTextStyle) { sample = .named(named) }

    private var backdrop: OverlayStageBackdrop {
        .init(
            mode: .init(rawValue: backdropMode) ?? .black, colorHex: backdropColorHex,
            videoPath: backdropVideoPath, time: backdropTime)
    }
    private var animated: Bool {
        switch sample {
        case .captions, .overlay: true
        default: false
        }
    }
    private var loop: Double {
        if case .overlay(let composition, _) = sample { return max(0.5, composition.wrappedValue.duration) }
        return max(0.5, duration)
    }
    private func time(at date: Date) -> Double {
        (pausedTime + (playing && !reduceMotion ? date.timeIntervalSince(started) * PlaybackSpeed.nearest(rate) : 0))
            .truncatingRemainder(dividingBy: loop)
    }

    var body: some View {
        VStack(spacing: 12) {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing || reduceMotion)) { context in
                ZStack {
                    backdrop.color
                    if let frame = backdrop.frame {
                        VideoThumbnail(url: frame.url, time: frame.time, cornerRadius: 0).allowsHitTesting(false)
                    }
                    stageSample(time: time(at: context.date))
                }
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    playbackControls
                    backdropPicker
                }
                VStack {
                    playbackControls
                    backdropPicker
                }
            }
            backdropDetails
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { scrubTime = backdropTime }
        .onChange(of: backdropVideoPath) {
            scrubTime = 0
            backdropTime = 0
        }
        .task(id: scrubTime) {
            do {
                try await Task.sleep(for: .milliseconds(120))
                backdropTime = scrubTime
            } catch {}
        }
        .onChange(of: rate) { old, _ in
            if playing {
                pausedTime += Date.now.timeIntervalSince(started) * PlaybackSpeed.nearest(old)
                started = .now
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                pausedTime = time(at: .now)
                playing = false
            }
        }
    }

    @ViewBuilder private func stageSample(time: Double) -> some View {
        switch sample {
        case .captions(let caption, let state):
            TextLooksCaptionSample(style: caption, selectedState: state, time: time, duration: $duration)
        case .tags(let tag, let state, let image):
            VStack {
                Spacer()
                TagStylePreview(style: tag, selection: image, transparentBackdrop: true, selectedState: state)
                Spacer().frame(height: 36)
            }
        case .overlay(let composition, let selection):
            OverlayPreviewCanvas(
                composition: composition, selection: selection,
                time: playing ? time : nil, backdrop: false, dimUnselected: true)
        case .named(let named):
            TextOverlayRasterPreview(item: namedSample(named))
        }
    }

    private func namedSample(_ named: NamedTextStyle) -> TextOverlayItem {
        var item = TextOverlayItem(text: "Make every word count")
        item.fontsize = 80
        item.xFrac = 0.5
        item.yFrac = 0.5
        item.decor = named.decor
        item.fontOverride = named.fontFamily
        return item
    }

    private var playbackControls: some View {
        ControlGroup {
            Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                pausedTime = time(at: .now)
                started = .now
                playing.toggle()
            }.disabled(!animated || reduceMotion).labelStyle(.iconOnly).help("Play or pause the sample")
            PlaybackSpeedControl(rate: $rate)
        }
    }
    private var backdropPicker: some View {
        Picker("Backdrop", selection: $backdropMode) {
            Text("Black").lineLimit(1).fixedSize().tag(OverlayStageBackdrop.Mode.black.rawValue)
            Text("Colour").lineLimit(1).fixedSize().tag(OverlayStageBackdrop.Mode.color.rawValue)
            Text("Source").lineLimit(1).fixedSize().tag(OverlayStageBackdrop.Mode.video.rawValue)
        }.pickerStyle(.segmented).help("Preview background; never included in the exported look.")
    }
    @ViewBuilder private var backdropDetails: some View {
        switch backdrop.mode {
        case .black: EmptyView()
        case .color:
            ColorPicker(selection: overlayColorBinding($backdropColorHex), supportsOpacity: false) {
                Text("Stage colour").lineLimit(1).fixedSize()
            }.help("Solid colour behind the preview")
        case .video:
            HStack(spacing: Theme.spaceS) {
                Text("Source").lineLimit(1).fixedSize()
                SourcePickerButton(
                    title: "Source", choices: store.videos.map(SourceChoice.init),
                    selection: store.videos.first { $0.url.path == backdropVideoPath }.map(SourceChoice.init)
                        ?? (backdropVideoPath.isEmpty ? nil : SourceChoice(otherFile: URL(fileURLWithPath: backdropVideoPath))),
                    placeholder: "Choose a source", caption: "Choose a source frame to judge the look against.",
                    actions: [SourceAction(title: "No source", systemImage: "xmark.circle", isCurrent: backdropVideoPath.isEmpty) { backdropVideoPath = "" }]
                ) { backdropVideoPath = $0.id }
            }
            .help("Choose a source frame to judge the look against")
            if let video = store.videos.first(where: { $0.url.path == backdropVideoPath }) {
                HStack {
                    Slider(value: $scrubTime, in: 0...max(0.1, video.duration)).help("Scrub the source frame")
                    TextField(
                        "Time", value: clampedTextLookNumber($scrubTime, in: 0...max(0.1, video.duration)),
                        format: .number.precision(.fractionLength(1))
                    )
                    .frame(width: 54).textFieldStyle(.roundedBorder).accessibilityLabel("Source time in seconds")
                }
            }
        }
    }
}

private struct TextLooksCaptionSample: View {
    @Binding var style: CaptionStyle
    @Binding var selectedState: String
    let time: Double
    @Binding var duration: Double
    @Environment(AppStore.self) private var store
    @AppStorage("captions.previewText") private var previewText = ""
    @State private var frames: [CaptionPreviewImage] = []
    @State private var images: [NSImage?] = []
    @State private var states: [(CaptionPreviewImage.WordState, NSImage)] = []
    @State private var error: String?
    private struct Input: Equatable {
        var style: CaptionStyle
        var text: String
    }
    private var input: Input { .init(style: style.applyingSharedStyle(store.activeProfile.textStyles ?? []), text: previewText) }

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / 1080
            ZStack(alignment: .topLeading) {
                if let index = frames.firstIndex(where: { $0.start <= time && time < $0.end }),
                    images.indices.contains(index), let image = images[index]
                {
                    Image(nsImage: image).resizable()
                        .frame(width: frames[index].size.width * scale, height: frames[index].size.height * scale)
                        .overlay { Rectangle().strokeBorder(selectedState == "Page" ? Color.accentColor : .clear) }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedState = "Page" }
                        .gesture(
                            DragGesture().onEnded { value in
                                let y = frames[index].origin.y * scale + value.translation.height
                                style.position = y < geo.size.height / 3 ? "top" : y < geo.size.height * 2 / 3 ? "middle" : "bottom"
                                selectedState = "Page"
                            }
                        )
                        .offset(x: frames[index].origin.x * scale, y: frames[index].origin.y * scale)
                        .accessibilityLabel("Caption page; drag to change position")
                }
                VStack(spacing: 8) {
                    TextField("Sample phrase", text: $previewText, prompt: Text(CaptionPreviewImage.sampleText))
                        .textFieldStyle(.roundedBorder).help("Words used by the preview; blank uses the stock sample")
                    // Each word is rendered in its actual state and selects that state's inspector.
                    HStack {
                        ForEach(states, id: \.0.id) { state, image in
                            Button {
                                selectedState = state.kind.rawValue
                            } label: {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 36)
                                    .overlay { Rectangle().strokeBorder(selectedState == state.kind.rawValue ? Color.accentColor : .clear) }
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit \(state.kind.rawValue)")
                            .help("Edit the \(state.kind.rawValue.lowercased()) word state")
                        }
                    }
                    if let error { FormCaption(error, tone: .warning) }
                }.padding(12)
            }
        }
        .task(id: input) {
            do {
                try await Task.sleep(for: .milliseconds(200))
                let snapshot = input
                let worker = Task.detached(priority: .userInitiated) {
                    (
                        try CaptionPreviewImage.frames(style: snapshot.style, text: snapshot.text),
                        try CaptionPreviewImage.wordStates(style: snapshot.style)
                    )
                }
                let (frames, states) = try await withTaskCancellationHandler(
                    operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                self.frames = frames
                images = frames.map { NSImage(data: $0.data) }
                self.states = states.compactMap { state in NSImage(data: state.image.data).map { (state, $0) } }
                duration = frames.last?.end ?? 3
                error = nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Could not render captions: \(error.localizedDescription)"
            }
        }
    }
}
