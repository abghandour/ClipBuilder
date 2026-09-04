import SwiftUI

/// Right-hand inspector: settings for the selected clip, sound block, or
/// text overlay (transitions, position, crop, mute, volume, captions, fonts).
struct BuilderInspector: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.builder
        ScrollView {
            inspectorContent(model: model)
                // With "Show scroll bars: Always" the scroller takes width;
                // content whose height follows its width (stills, wrapped
                // text) can then flip the scroller on and off forever. Keep
                // it always present so the width never changes.
                .background(PinnedVerticalScroller())
        }
    }

    @ViewBuilder
    private func inspectorContent(model: BuilderTimelineModel) -> some View {
        Group {
            switch model.selection {
            case .clip(let uid):
                if let clip = model.clip(uid) {
                    ClipInspector(clip: clip)
                } else {
                    placeholder
                }
            case .sound(let uid):
                if let index = model.soundIndex(uid) {
                    SoundInspector(item: model.document.soundTrack[index])
                } else {
                    placeholder
                }
            case .text(let uid):
                if let item = model.textItem(uid) {
                    TextInspector(item: item)
                } else {
                    placeholder
                }
            case .image(let uid):
                if let item = model.imageItem(uid) {
                    ImageInspector(item: item)
                } else {
                    placeholder
                }
            case .overlay(let uid):
                if let item = model.overlayBlock(uid) {
                    OverlayBlockInspector(item: item)
                } else {
                    placeholder
                }
            case .crop(let uid):
                if let block = model.cropBlock(uid) {
                    CropBlockInspector(block: block)
                } else {
                    placeholder
                }
            case nil:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Select a clip, crop block, music block, or overlay to edit its settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

/// Transition picker choices: hard cut, the action pack (recipe bridges +
/// flash cuts), then every xfade the engine supports.
private let transitionChoices = ["cut"] + RenderEngine.actionTransitions + RenderEngine.transitions

struct ClipInspector: View {
    @Environment(AppStore.self) private var store
    let clip: TimelineClip


    /// Wide-clip framing controls (slot position, 9:16 crop, tracking
    /// reframe) only apply under a Full Screen block: under an area the
    /// renderer frames the clip into that area with its own camera and
    /// discards them.
    private var framesItself: Bool {
        store.builder.document.cropBlock(at: clip.startTime)?.layout.isFullScreen ?? true
    }

    var body: some View {
        let model = store.builder
        let area = model.area(forTrack: clip.track, at: clip.startTime)
        VStack(alignment: .leading, spacing: Theme.spaceL) {
            // Header
            HStack(spacing: Theme.spaceS) {
                if let url = model.sourceURL(for: clip) {
                    VideoThumbnail(url: url, time: clip.sourceStart ?? 0,
                                   cornerRadius: Theme.mediaRadius)
                        .frame(width: 34, height: 48)
                } else {
                    Image(systemName: "film")
                        .frame(width: 34, height: 48)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: Theme.spaceXS) {
                    Text(model.scene(for: clip)?.videoFilename
                         ?? (clip.videoFile as NSString?)?.lastPathComponent ?? "Clip")
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(clip.startTime.timecode) · \(String(format: "%.1fs", clip.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Trim against the raw video, right under the clip identity.
            InspectorSection("Trim") {
                ClipTrimEditor(clip: clip)
            }

            // Framing — the decision that changes the picture most.
            InspectorSection("Framing") {
                if let area {
                    InspectorRow("Crop area") {
                        Text(area.name)
                            .help("Set by the cropping row: this track shows this area while the clip starts")
                    }
                    AreaWindowEditor(clip: clip, area: area)
                } else if model.document.isOrphaned(clip) {
                    Label("No crop area on this track here — this stretch will not render. Move the clip or change the crop block.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                } else if clip.wide {
                    InspectorRow("Position") {
                        Picker("Position", selection: Binding(
                            get: { clip.position ?? "layer" },
                            set: { value in
                                model.updateClip(clip.uid) { $0.position = value == "layer" ? nil : value }
                            })) {
                            Text("Track default").tag("layer")
                            Text("Top").tag("top")
                            Text("Center").tag("center")
                            Text("Bottom").tag("bottom")
                        }
                        .labelsHidden()
                        .help("Where a wide clip sits when it is not cropped to 9:16")
                    }
                    InspectorRow("Crop") {
                        Toggle("Crop to 9:16", isOn: Binding(
                            get: { clip.cropXFrac != nil },
                            set: { value in model.updateClip(clip.uid) { $0.cropXFrac = value ? 0.5 : nil } }))
                    }
                    if let crop = clip.cropXFrac {
                        Slider(value: Binding(
                            get: { crop },
                            set: { value in model.updateClip(clip.uid) { $0.cropXFrac = value } }),
                            in: 0...1)
                            .accessibilityLabel("Wide clip crop position")
                        cropPreview(fraction: crop)
                    }
                    InspectorRow("Camera") {
                        Toggle("Tracking reframe", isOn: binding(\.centerStage))
                            .help("Follow the action with a tracking camera instead of the static crop")
                    }
                } else {
                    Text("Full screen. Portrait clips fill the frame as they are.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Custom crop rectangles predate the cropping row and
                // bypass it in the renderer; older timelines can still
                // carry them, so they stay removable but cannot be added.
                if let crops = clip.freeCrops, !crops.isEmpty {
                    Label("Custom crops (legacy) — these override the crop area.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    ForEach(crops.indices, id: \.self) { index in
                        HStack {
                            Image(systemName: "crop")
                                .foregroundStyle(.secondary)
                            Text("Crop \(index + 1)")
                            Spacer()
                            Button("Remove Crop", systemImage: "trash") { removeCrop(at: index) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Remove Crop \(index + 1)")
                        }
                        .font(.caption)
                    }
                }
            }

            InspectorSection("Sound") {
                InspectorRow("Volume") {
                    HStack(spacing: Theme.spaceS) {
                        Picker("Volume", selection: binding(\.volume)) {
                            ForEach(1...5, id: \.self) { level in
                                Text("\(level)").tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(clip.muted)
                        Toggle("Muted", isOn: binding(\.muted))
                    }
                }
            }

            InspectorSection("Transitions") {
                InspectorRow("In") {
                    Picker("Transition in", selection: transitionBinding(\.transIn)) {
                        ForEach(transitionChoices, id: \.self) { name in
                            Text(TransitionCatalog.title(for: name)).tag(name)
                        }
                    }
                    .labelsHidden()
                    .help("Effects are previewed in Resources → Effects")
                }
                InspectorRow("Out") {
                    Picker("Transition out", selection: transitionBinding(\.transOut)) {
                        ForEach(transitionChoices, id: \.self) { name in
                            Text(TransitionCatalog.title(for: name)).tag(name)
                        }
                    }
                    .labelsHidden()
                }
            }

            InspectorSection("Playback") {
                InspectorRow("Speed") {
                    Picker("Speed", selection: Binding(
                        get: { clip.speed ?? 1 },
                        set: { value in
                            model.updateClip(clip.uid) { updated in
                                let span = updated.duration * (updated.speed ?? 1)
                                updated.speed = value == 1 ? nil : value
                                updated.duration = ((span / value) * 10).rounded() / 10
                            }
                        })) {
                        Text("0.5× slow").tag(0.5)
                        Text("0.75×").tag(0.75)
                        Text("1× normal").tag(1.0)
                        Text("1.5×").tag(1.5)
                        Text("2×").tag(2.0)
                    }
                    .labelsHidden()
                    .help("Change playback speed; timeline length adjusts to preserve the source span")
                }
                InspectorRow("Captions") {
                    Picker("Captions", selection: binding(\.captions)) {
                        ForEach(TimelineClip.captionChoices, id: \.self) { choice in
                            Text(choice.capitalized).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .help("Inherit uses the track's caption setting")
                }
            }

            Divider()

            HStack {
                Button("Duplicate") { model.duplicateClip(clip.uid) }
                Spacer()
                Button("Delete", role: .destructive) { model.removeClip(clip.uid) }
            }
            .controlSize(.small)
        }
        .padding(Theme.spaceM)
    }

    private func removeCrop(at index: Int) {
        store.builder.updateClip(clip.uid) {
            guard var crops = $0.freeCrops, crops.indices.contains(index) else { return }
            crops.remove(at: index)
            $0.freeCrops = crops.isEmpty ? nil : crops
        }
    }

    private func cropPreview(fraction: Double) -> some View {
        let model = store.builder
        return Group {
            if let url = model.sourceURL(for: clip) {
                VideoThumbnail(url: url, time: clip.sourceStart ?? 0, cornerRadius: 4)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 150)
                    .frame(height: 150)
                    .overlay {
                        GeometryReader { geo in
                            let windowWidth = geo.size.height * 9 / 16
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                .frame(width: windowWidth, height: geo.size.height)
                                .offset(x: (geo.size.width - windowWidth) * fraction)
                        }
                    }
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<TimelineClip, T>) -> Binding<T> {
        let model = store.builder
        let uid = clip.uid
        let fallback = clip[keyPath: keyPath]
        return Binding(
            get: { model.clip(uid)?[keyPath: keyPath] ?? fallback },
            set: { value in model.updateClip(uid) { $0[keyPath: keyPath] = value } })
    }

    private func transitionBinding(_ keyPath: WritableKeyPath<TimelineClip, String?>) -> Binding<String> {
        let model = store.builder
        let uid = clip.uid
        return Binding(
            get: { model.clip(uid)?[keyPath: keyPath] ?? "cut" },
            set: { value in model.updateClip(uid) { $0[keyPath: keyPath] = value == "cut" ? nil : value } })
    }
}

struct SoundInspector: View {
    @Environment(AppStore.self) private var store
    let item: SoundItem

    var body: some View {
        let model = store.builder
        VStack(alignment: .leading, spacing: 12) {
            Label(item.name, systemImage: "music.note")
                .font(.headline)
                .lineLimit(1)
            Picker("Volume", selection: Binding(
                get: { item.volume },
                set: { value in model.updateSound(item.uid) { $0.volume = value } })) {
                ForEach(1...5, id: \.self) { level in
                    Text("\(level)").tag(level)
                }
            }
            .pickerStyle(.segmented)
            LabeledContent("Start") {
                Text(item.startTime.timecode).monospacedDigit()
            }
            Stepper(String(format: "Duration: %.1fs", item.duration),
                    value: Binding(
                        get: { item.duration },
                        set: { value in model.updateSound(item.uid) { $0.duration = value } }),
                    in: 0.5...600, step: 0.5)
            Divider()
            Button("Delete", role: .destructive) { model.removeSound(item.uid) }
                .controlSize(.small)
        }
        .padding(12)
    }
}

struct ImageInspector: View {
    @Environment(AppStore.self) private var store
    let item: ImageOverlayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Image Overlay")
                .font(.headline)

            ImageOverlayControls(item: itemBinding, name: item.displayName)

            Picker("Enter", selection: itemBinding.transIn) {
                ForEach(TextOverlayItem.transitionChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            Picker("Exit", selection: itemBinding.transOut) {
                ForEach(TextOverlayItem.transitionChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }

            LabeledContent("Timing") {
                Text("\(item.startTime.timecode)–\(item.endTime.timecode)").monospacedDigit()
            }

            Divider()
            Button("Delete", role: .destructive) { store.builder.removeImage(item.uid) }
                .controlSize(.small)
        }
        .padding(12)
    }

    /// Edits route through updateImage so undo registration and time clamping
    /// stay in one place.
    private var itemBinding: Binding<ImageOverlayItem> {
        let model = store.builder
        let uid = item.uid
        let fallback = item
        return Binding(
            get: { model.imageItem(uid) ?? fallback },
            set: { value in model.updateImage(uid) { $0 = value } })
    }
}

struct TextInspector: View {
    @Environment(AppStore.self) private var store
    let item: TextOverlayItem

    @State private var savingTemplate = false
    @State private var templateName = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text Overlay")
                .font(.headline)

            TextOverlayForm(item: itemBinding)

            Picker("Enter", selection: itemBinding.transIn) {
                ForEach(TextOverlayItem.transitionChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            Picker("Exit", selection: itemBinding.transOut) {
                ForEach(TextOverlayItem.transitionChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }

            LabeledContent("Timing") {
                Text("\(item.startTime.timecode)–\(item.endTime.timecode)").monospacedDigit()
            }

            Divider()
            HStack {
                Button("Save as Template…", action: promptForTemplateName)
                    .controlSize(.small)
                    .help("Save this overlay's look to the Overlays library for reuse in the Builder and AI Wizard")
                Spacer()
                Button("Delete", role: .destructive) { store.builder.removeText(item.uid) }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .alert("Save as Template", isPresented: $savingTemplate) {
            TextField("Template name", text: $templateName)
            Button("Save", action: saveTemplate)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Templates appear in the Overlays section and in the AI Wizard's style palette.")
        }
        .alert("Error", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    /// Edits route through updateText so undo registration and time clamping
    /// stay in one place.
    private var itemBinding: Binding<TextOverlayItem> {
        let model = store.builder
        let uid = item.uid
        let fallback = item
        return Binding(
            get: { model.textItem(uid) ?? fallback },
            set: { value in model.updateText(uid) { $0 = value } })
    }

    private func promptForTemplateName() {
        let firstLine = item.text.components(separatedBy: .newlines).first ?? ""
        templateName = OverlayTemplateStore.uniqueName(base: firstLine.isEmpty ? "Template" : firstLine)
        savingTemplate = true
    }

    private func saveTemplate() {
        let name = OverlayTemplateStore.uniqueName(base: templateName)
        // Template timing is relative to the composition start, and a text
        // saved from the Builder is the headline the AI Wizard may rewrite.
        var text = item
        text.startTime = 0
        text.endTime = max(0.5, item.duration)
        text.isDynamic = true
        do {
            try OverlayTemplateStore.save(OverlayTemplate(name: name,
                                                          composition: OverlayComposition(texts: [text])))
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// A placed overlay-template block: timing controls plus a summary of the
/// snapshot it renders. The design itself is edited in the Overlays section
/// (and re-added, since placed blocks are snapshots).
struct OverlayBlockInspector: View {
    @Environment(AppStore.self) private var store
    let item: OverlayBlockItem

    var body: some View {
        let model = store.builder
        VStack(alignment: .leading, spacing: 12) {
            Label(item.name, systemImage: "square.2.layers.3d")
                .font(.headline)
                .lineLimit(1)

            Text("\(item.composition.texts.count) text(s) · \(item.composition.images.count) image(s)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            LabeledContent("Start") {
                Text(item.startTime.timecode).monospacedDigit()
            }
            Stepper(value: Binding(
                get: { item.duration },
                set: { value in model.updateOverlayBlock(item.uid) { $0.duration = max(0.5, value) } }),
                in: 0.5...600, step: 0.5) {
                LabeledContent("Duration") {
                    Text(String(format: "%.1fs", item.duration)).monospacedDigit()
                }
            }

            Divider()

            Text("This block is a snapshot of the template as it was when added. Edit the design in the Overlays section and re-add it to pick up changes.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Delete Overlay", role: .destructive) {
                model.removeOverlayBlock(item.uid)
            }
        }
        .padding(12)
    }
}

/// Settings for one block of the cropping row: its Screen Crop layout,
/// timing, and the track ↔ area mapping.
struct CropBlockInspector: View {
    @Environment(AppStore.self) private var store
    let block: CropBlockItem

    var body: some View {
        let model = store.builder
        let areas = block.layout.orderedAreas
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Crop Block")
                .font(.headline)

            Picker("Layout", selection: Binding(
                get: { block.layout },
                set: { model.setCropLayout($0, for: block.uid) })) {
                ForEach(BuilderTimelineModel.availableCropLayouts(), id: \.self) { layout in
                    Text(layout.displayName).tag(layout)
                }
                if block.layout.isMissing {
                    Text("\(block.layout.name) (missing)").tag(block.layout)
                }
            }
            .help("Layouts come from Resources > Screen Crop")

            LabeledContent("From", value: block.startTime.timecode)
            LabeledContent("To", value: block.endTime.timecode)
            Stepper("Length: \(String(format: "%.1fs", block.duration))",
                    value: Binding(
                        get: { block.duration },
                        set: { model.resizeCropBlock(block.uid, duration: $0) }),
                    in: 0.5...600, step: 0.5)
                .help("Growing eats into the following blocks; shrinking leaves Full Screen behind")

            if block.layout.isFullScreen {
                Text("One area covering the whole frame. Track I fills the screen; other tracks have no area here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if block.layout.isMissing {
                Label("This layout no longer exists in Resources. It renders full screen until you pick another.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            } else {
                VStack(alignment: .leading, spacing: Theme.spaceXS) {
                    Text("Tracks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(areas.enumerated()), id: \.offset) { index, area in
                        let clips = model.clips(inTrack: index, within: block)
                        HStack(alignment: .top, spacing: Theme.spaceS) {
                            CropLayoutDiagram(areas: areas, highlightedIndex: index)
                                .frame(width: 18, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Theme.spaceXS) {
                                    Text("Track \(index + 1)")
                                        .font(.caption.weight(.semibold))
                                    Text(area.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                // The videos that fill this area during the block.
                                if clips.isEmpty {
                                    Text("No clip here — drop one on Track \(index + 1)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                } else {
                                    ForEach(clips) { clip in
                                        HStack(spacing: Theme.spaceXS) {
                                            if let url = model.sourceURL(for: clip) {
                                                VideoThumbnail(url: url, time: clip.sourceStart ?? 0,
                                                               cornerRadius: 3)
                                                    .frame(width: 28, height: 16)
                                            }
                                            Text(model.scene(for: clip)?.videoFilename
                                                 ?? clip.videoFile.map { ($0 as NSString).lastPathComponent }
                                                 ?? "Clip")
                                                .font(.caption2)
                                                .lineLimit(1)
                                            Text(clip.startTime.timecode)
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            model.selection = .clip(clip.uid)
                                            model.focusedTrack = clip.track
                                            model.playhead = BuilderTimelineModel.snap(
                                                max(clip.startTime, block.startTime))
                                        }
                                        .help("Select this clip and preview it")
                                    }
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .onTapGesture { model.focusTrack(index) }
                        .background(model.highlightedTrack == index ? Color.green.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            Button("Split at Playhead") { model.splitCropBlock() }
                .controlSize(.small)
                .disabled(!(model.playhead > block.startTime + 0.499 && model.playhead < block.endTime - 0.499))
            Button("Delete Crop Block", role: .destructive) { model.removeCropBlock(block.uid) }
                .controlSize(.small)
                .disabled(block.layout.isFullScreen)
        }
        .padding(Theme.spaceM)
    }
}

/// The part of the source that fills the clip's crop area: a still of the
/// clip with the area's shape drawn over it at the area's aspect ratio.
/// Drag the shape to choose what the area shows; drag a corner to resize it
/// (the aspect is locked to the area). Until the shape is moved, the
/// tracking camera frames the area automatically.
struct AreaWindowEditor: View {
    @Environment(AppStore.self) private var store
    let clip: TimelineClip
    let area: ScreenCropArea

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    @State private var drag: (corner: Corner?, start: FreeCropRect)?

    private static let minWidth = 0.1
    static let stillHeight: CGFloat = 170

    /// Source frame size in pixels (falls back to 16:9).
    private var sourceSize: CGSize {
        let model = store.builder
        let video = model.scene(for: clip).flatMap { scene in store.videos.first { $0.id == scene.videoID } }
            ?? store.videos.first { $0.path == clip.videoFile }
        guard let video, video.width > 0, video.height > 0 else { return CGSize(width: 16, height: 9) }
        return CGSize(width: video.width, height: video.height)
    }

    private var window: FreeCropRect {
        clip.areaWindow ?? AreaFramer.defaultWindow(for: area, sourceSize: sourceSize)
    }

    var body: some View {
        let model = store.builder
        let time = model.playhead >= clip.startTime && model.playhead < clip.startTime + clip.duration
            ? model.sourceTime(for: clip, atTimeline: model.playhead) : (clip.sourceStart ?? 0)
        let size = sourceSize
        VStack(alignment: .leading, spacing: Theme.spaceXS) {
            if let url = model.sourceURL(for: clip) {
                GeometryReader { geo in
                    let fitted = geo.size
                    ZStack(alignment: .topLeading) {
                        VideoThumbnail(url: url, time: time, cornerRadius: 4)
                            .frame(width: fitted.width, height: fitted.height)
                        // Dim everything the area will not show: the frame
                        // minus the window shape, filled even-odd.
                        Path { path in
                            path.addRect(CGRect(origin: .zero, size: fitted))
                            path.addPath(windowShape(fitted: fitted)
                                .path(in: CGRect(origin: .zero, size: fitted)))
                        }
                        .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                        .frame(width: fitted.width, height: fitted.height)
                        .allowsHitTesting(false)
                        windowOverlay(fitted: fitted)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .aspectRatio(size.width / max(1, size.height), contentMode: .fit)
                // A fixed-height box: the still's height must not follow the
                // pane width, or the scroller toggling would re-layout it.
                .frame(maxWidth: .infinity, maxHeight: Self.stillHeight)
                .frame(height: Self.stillHeight)
            }
            HStack {
                Text(clip.areaWindow == nil
                     ? "Tracking camera. Drag the shape to place the area by hand."
                     : "Hand-placed: this part of the video fills the \"\(area.name)\" area.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if clip.areaWindow != nil {
                    Button("Use Tracking Camera") {
                        model.updateClip(clip.uid) { $0.areaWindow = nil }
                    }
                    .controlSize(.small)
                    .help("Let the tracking camera frame the area again")
                }
            }
        }
    }

    /// The area's polygon, normalized to its bounding box and fitted into
    /// the window rect — the shape the area really cuts out.
    private func windowShape(fitted: CGSize) -> ScreenCropPolygon {
        let box = area.bounds
        let rect = windowRect(fitted: fitted)
        let points = area.points.map { point in
            ScreenCropPoint(x: (rect.minX + (point.x - box.x) / max(0.001, box.w) * rect.width) / fitted.width,
                            y: (rect.minY + (point.y - box.y) / max(0.001, box.h) * rect.height) / fitted.height)
        }
        return ScreenCropPolygon(points: points)
    }

    private func windowRect(fitted: CGSize) -> CGRect {
        let w = window
        return CGRect(x: w.xFrac * fitted.width, y: w.yFrac * fitted.height,
                      width: w.wFrac * fitted.width, height: w.hFrac * fitted.height)
    }

    @ViewBuilder
    private func windowOverlay(fitted: CGSize) -> some View {
        let rect = windowRect(fitted: fitted)
        let placed = clip.areaWindow != nil
        windowShape(fitted: fitted)
            .stroke(placed ? Color.accentColor : Color.white.opacity(0.85),
                    style: StrokeStyle(lineWidth: 2, dash: placed ? [] : [5, 3]))
            .frame(width: fitted.width, height: fitted.height)
            .allowsHitTesting(false)
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .gesture(dragGesture(corner: nil, fitted: fitted))
            .help("Drag to choose what the area shows")
        ForEach(Corner.allCases, id: \.self) { corner in
            Circle()
                .fill(placed ? Color.accentColor : Color.white)
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                .position(handlePosition(corner, rect: rect))
                .gesture(dragGesture(corner: corner, fitted: fitted))
                .help("Drag to resize (keeps the area's proportions)")
        }
    }

    private func handlePosition(_ corner: Corner, rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func dragGesture(corner: Corner?, fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if drag == nil || drag?.corner != corner {
                    drag = (corner, window)
                }
                guard let drag else { return }
                let updated = Self.transformed(drag.start, corner: corner,
                                               dx: value.translation.width / fitted.width,
                                               dy: value.translation.height / fitted.height,
                                               heightPerWidth: drag.start.hFrac / max(0.001, drag.start.wFrac))
                store.builder.updateClip(clip.uid) { $0.areaWindow = updated }
            }
            .onEnded { _ in drag = nil }
    }

    /// Move (corner == nil) or corner-resize keeping the aspect ratio
    /// (`heightPerWidth` in fraction space), clamped inside the frame.
    private static func transformed(_ start: FreeCropRect, corner: Corner?,
                                    dx: Double, dy: Double, heightPerWidth: Double) -> FreeCropRect {
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), high) }
        if corner == nil {
            var rect = start
            rect.xFrac = clamp(start.xFrac + dx, 0, 1 - start.wFrac)
            rect.yFrac = clamp(start.yFrac + dy, 0, 1 - start.hFrac)
            return rect
        }
        // The dragged corner moves; the opposite corner stays put. Width
        // follows the pointer, height follows width.
        let right = start.xFrac + start.wFrac
        let bottom = start.yFrac + start.hFrac
        let growsRight = corner == .topRight || corner == .bottomRight
        let growsDown = corner == .bottomLeft || corner == .bottomRight
        let widthDelta = growsRight ? dx : -dx
        // Let a mostly vertical drag resize too.
        let heightDelta = growsDown ? dy : -dy
        let delta = abs(widthDelta) >= abs(heightDelta / heightPerWidth) ? widthDelta : heightDelta / heightPerWidth
        var width = max(minWidth, start.wFrac + delta)
        // Keep the anchored edges inside the frame.
        let maxWidthX = growsRight ? 1 - start.xFrac : right
        let maxWidthY = (growsDown ? 1 - start.yFrac : bottom) / heightPerWidth
        width = min(width, maxWidthX, maxWidthY)
        let height = width * heightPerWidth
        return FreeCropRect(xFrac: growsRight ? start.xFrac : right - width,
                            yFrac: growsDown ? start.yFrac : bottom - height,
                            wFrac: width, hFrac: height)
    }
}

/// A flat inspector section: a small uppercase title over its controls.
/// No disclosure — everything is visible, in order of importance.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            content
        }
    }
}

/// One labeled control row with labels right-aligned in a shared column so
/// the controls line up down the inspector.
struct InspectorRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    static var labelWidth: CGFloat { 72 }

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.spaceS) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Finds the enclosing NSScrollView and keeps its vertical scroller from
/// auto-hiding. Harmless with overlay scrollers; with legacy ("Always")
/// scrollers it stops the show/hide layout feedback loop.
private struct PinnedVerticalScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { pin(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { pin(from: nsView) }
    }

    private func pin(from view: NSView) {
        var current = view.superview
        while let candidate = current {
            if let scrollView = candidate as? NSScrollView {
                if scrollView.autohidesScrollers || !scrollView.hasVerticalScroller {
                    scrollView.hasVerticalScroller = true
                    scrollView.autohidesScrollers = false
                }
                return
            }
            current = candidate.superview
        }
    }
}
