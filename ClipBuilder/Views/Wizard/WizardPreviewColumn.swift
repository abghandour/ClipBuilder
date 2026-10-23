import SwiftUI

/// An element the user can drag to a new place in the preview.
enum PreviewElement: String, Sendable {
    case caption, nameTag, overlay

    var label: String {
        switch self {
        case .caption: "caption"
        case .nameTag: "name tag"
        case .overlay: "overlay"
        }
    }
}

/// A sibling of the settings form, so the scene stays visible while editing.
struct WizardPreviewColumn: View {
    @Environment(AppStore.self) private var store
    let scenes: [SceneRecord]
    /// Kept footage in output order. When present the column previews these
    /// stretches with a scrubber instead of stepping through analysis scenes.
    let clips: [WizardPreviewClip]
    let options: WizardOptions
    let profile: BrandProfile
    /// Pinned under the preview: Express puts its run summary and Generate here.
    var footer: AnyView? = nil
    /// Called when the user drops a dragged element; the owner stores the
    /// position in its settings and the preview re-renders from them.
    var onMove: ((PreviewElement, CustomPosition) -> Void)? = nil
    @State private var model: WizardPreviewModel
    @State private var reloadID = 0
    @State private var clipIndex = 0
    /// Scrubber position in source seconds; nil shows the middle of the clip.
    @State private var scrubTime: Double?

    init(scenes: [SceneRecord], clips: [WizardPreviewClip] = [], options: WizardOptions, profile: BrandProfile,
         thumbnails: ThumbnailService, footer: AnyView? = nil,
         onMove: ((PreviewElement, CustomPosition) -> Void)? = nil) {
        self.scenes = scenes
        self.clips = clips
        self.options = options
        self.profile = profile
        self.footer = footer
        self.onMove = onMove
        _model = State(initialValue: WizardPreviewModel(thumbnails: thumbnails))
    }

    private var currentClip: WizardPreviewClip? {
        clips.isEmpty ? nil : clips[min(clipIndex, clips.count - 1)]
    }

    /// The scene the still is read from: the kept clip's, else the stepper's.
    private var previewRecord: SceneRecord? { currentClip?.scene ?? model.selectedScene }

    private var previewTime: Double? {
        guard let clip = currentClip else { return nil }
        return min(clip.end, max(clip.start, scrubTime ?? (clip.start + clip.end) / 2))
    }

    private struct ContentKey: Equatable {
        var scene: SceneRecord?
        var generation: Int
        var transcriptVersion: Int
        var people: [PersonRecord]
        /// Bumped when a tag field (Role, Team, handle) is saved for a person.
        var tagFieldsVersion: Int
        var language: String?
        var tagStyle: TagStyle
        var reloadID: Int
        var cameraFocus: String
        var interviewZoom: Double
        var interviewZoomMoves: Bool
        var canvasAspect: Double
        var clipID: String?
        /// Scrubber moment, rounded so a slider's sub-frame jitter does not reload.
        var time: Double?
    }

    private var contentKey: ContentKey {
        ContentKey(scene: previewRecord, generation: store.profileGeneration,
            transcriptVersion: store.transcriptCountsVersion, people: store.people,
            tagFieldsVersion: store.personTagFieldsVersion, language: options.captionLanguage, tagStyle: profile.tagStyle(id: options.nameTagStyleID), reloadID: reloadID,
            cameraFocus: options.podcastFraming == .original ? WizardCameraFocus.original : options.highlightFraming?.rawValue ?? "",
            interviewZoom: options.interviewZoom ?? 0, interviewZoomMoves: options.interviewZoomMoves ?? false,
            canvasAspect: options.renderSettings.aspectRatio,
            clipID: currentClip?.id, time: previewTime.map { ($0 * 20).rounded() / 20 })
    }

    private func key(overlayTexts: [String]) -> PreviewKey? {
        guard let record = previewRecord else { return nil }
        return PreviewKey(options: options, scene: record, profile: profile,
                          contentRevision: model.contentRevision, overlayTexts: overlayTexts, time: previewTime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceS) {
                    title
                    Spacer(minLength: 0)
                    stepper
                    chromePicker
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    HStack {
                        title
                        Spacer(minLength: 0)
                        chromePicker
                    }
                    stepper
                }
            }
            GeometryReader { available in
                // Size the image explicitly so the scrubber and captions sit
                // flush under it; a flexible frame would keep its full height.
                let aspect = max(0.01, options.renderSettings.aspectRatio)
                let height = min(max(120, available.size.height - (currentClip == nil ? 88 : 120)),
                                 available.size.width / aspect)
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    preview
                        .frame(width: height * aspect, height: height)
                    if let clip = currentClip { scrubber(clip).frame(width: height * aspect) }
                    if let error = model.error {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Retry preview") { reloadID += 1 }
                            .lineLimit(1).fixedSize()
                    }
                    if let warning = model.scene?.framingWarning {
                        Text(warning).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text((currentClip == nil
                        ? "One scene with the current Picture and Overlays settings. Position choices set to Auto are resolved for this scene."
                        : "Your kept footage with the current Picture and Overlays settings. Drag to any moment; position choices set to Auto are resolved for it.")
                        + (onMove == nil ? "" : " Drag the caption, a name tag or the overlay to place it."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let footer {
                Divider()
                footer
            }
        }
        .padding(Theme.spaceM)
        .onChange(of: scenes, initial: true) { _, values in model.setScenes(values) }
        .onChange(of: clips.map(\.id)) { _, ids in
            if clipIndex >= ids.count { clipIndex = 0 }
            scrubTime = nil
        }
        .task(id: contentKey) {
            model.cancel()
            // A dragged scrubber changes the key many times a second; load
            // once the hand pauses.
            if contentKey.time != nil {
                try? await Task.sleep(for: .milliseconds(120))
                if Task.isCancelled { return }
            }
            await model.loadScene(previewRecord, database: store.database, people: store.people,
                                  language: options.captionLanguage, tagStyleID: options.nameTagStyleID, profile: profile, options: options,
                                  range: currentClip?.range, time: previewTime)
            if !Task.isCancelled { refresh() }
        }
        // The cache key includes the text snapshot used by the next render.
        .onChange(of: key(overlayTexts: []), initial: true) { _, _ in refresh() }
        // Typed replacement texts re-render after a short pause so the preview
        // shows what the user wrote without rendering on every keystroke.
        .task(id: options.fixedOverlayTexts ?? []) {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { refresh() }
        }
        .onDisappear { model.cancel() }
    }

    private var title: some View {
        Text("Preview").font(.headline).lineLimit(1).fixedSize()
    }

    private var chromePicker: some View {
        PlatformChromePicker().labelStyle(.iconOnly).lineLimit(1).fixedSize()
    }

    @ViewBuilder
    private var stepper: some View {
        if clips.isEmpty { sceneStepper } else { clipStepper }
    }

    private var clipStepper: some View {
        HStack(spacing: Theme.spaceS) {
            Button("Previous clip", systemImage: "chevron.left") { clipIndex -= 1; scrubTime = nil }
                .disabled(clipIndex <= 0)
            Text("Clip \(min(clipIndex, clips.count - 1) + 1) of \(clips.count)")
                .font(.caption).monospacedDigit().lineLimit(1).fixedSize()
            Button("Next clip", systemImage: "chevron.right") { clipIndex += 1; scrubTime = nil }
                .disabled(clipIndex + 1 >= clips.count)
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .lineLimit(1).fixedSize()
    }

    /// Source-time scrubber across the kept clip, with the moment shown as
    /// output time so it reads like the player's clock.
    private func scrubber(_ clip: WizardPreviewClip) -> some View {
        let shown = (previewTime ?? clip.start) - clip.start
        return HStack(spacing: Theme.spaceS) {
            Slider(value: Binding(
                get: { shown },
                set: { scrubTime = clip.start + min(clip.duration, max(0, $0)) }), in: 0...max(0.01, clip.duration))
                .controlSize(.small)
                .accessibilityLabel("Preview moment")
            Text("\(WizardPreviewClips.clock(shown)) / \(WizardPreviewClips.clock(clip.duration))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }

    private var sceneStepper: some View {
        HStack(spacing: Theme.spaceS) {
            Button("Previous scene", systemImage: "chevron.left") { model.sceneIndex -= 1 }
                .disabled(model.sceneIndex <= 0 || model.scenes.isEmpty)
            Text("Scene \(model.scenes.isEmpty ? 0 : model.sceneIndex + 1) of \(model.scenes.count)")
                .font(.caption).monospacedDigit().lineLimit(1).fixedSize()
            Button("Next scene", systemImage: "chevron.right") { model.sceneIndex += 1 }
                .disabled(model.sceneIndex + 1 >= model.scenes.count)
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .lineLimit(1).fixedSize()
    }

    private var preview: some View {
        Color.black
            .overlay {
                if model.selectedScene == nil {
                    Text("Choose a video to preview")
                        .font(.callout).foregroundStyle(.white)
                        .multilineTextAlignment(.center).padding(Theme.spaceM)
                } else if let image = model.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .accessibilityLabel("Scene preview with the current settings")
                }
            }
            .overlay {
                if model.selectedScene != nil {
                    GeometryReader { geometry in
                        PlatformChromeLayer(size: geometry.size,
                                            safeAreaSettings: options.renderSettings.platformSafeArea)
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if let onMove, let layout = model.layout, model.image != nil {
                    GeometryReader { geometry in
                        PreviewHandlesLayer(layout: layout, canvas: CGSize(width: options.renderSettings.width,
                                                                           height: options.renderSettings.height),
                                            size: geometry.size, onMove: onMove)
                    }
                }
            }
            .overlay {
                if model.isRendering || model.isLoadingScene {
                    ProgressView().controlSize(.small).padding(Theme.spaceS)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Updating preview")
                }
            }
            .clipped()
    }

    private func refresh() {
        guard let record = previewRecord, model.loadedSceneID == record.id,
              let scene = model.scene, let key = key(overlayTexts: options.fixedOverlayTexts ?? []) else { return }
        model.update(key: key) {
            .init(scene: scene, options: options, profile: profile, templates: model.templates, frameData: Data())
        }
    }
}

/// Hover-revealed handles over the preview's caption, name tags and
/// overlay. A drag moves the outline; the drop reports the element's new
/// centre as canvas fractions.
private struct PreviewHandlesLayer: View {
    let layout: WizardPreviewComposite.Layout
    let canvas: CGSize
    let size: CGSize
    let onMove: (PreviewElement, CustomPosition) -> Void

    private var scale: CGFloat {
        guard canvas.width > 0, canvas.height > 0 else { return 1 }
        return min(size.width / canvas.width, size.height / canvas.height)
    }

    private var origin: CGPoint {
        CGPoint(x: (size.width - canvas.width * scale) / 2, y: (size.height - canvas.height * scale) / 2)
    }

    private func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let rect = layout.overlay {
                PreviewHandle(element: .overlay, rect: viewRect(rect), size: size, onMove: onMove)
            }
            ForEach(Array(layout.tags.enumerated()), id: \.offset) { _, rect in
                PreviewHandle(element: .nameTag, rect: viewRect(rect), size: size, onMove: onMove)
            }
            if let rect = layout.caption {
                PreviewHandle(element: .caption, rect: viewRect(rect), size: size, onMove: onMove)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

private struct PreviewHandle: View {
    let element: PreviewElement
    /// The element's rect in the preview view's coordinates.
    let rect: CGRect
    /// The preview view's size, which the drop maps to canvas fractions.
    let size: CGSize
    let onMove: (PreviewElement, CustomPosition) -> Void
    @State private var translation = CGSize.zero
    @State private var hovering = false

    var body: some View {
        let active = hovering || translation != .zero
        // A faint outline says the element can be moved; it brightens on hover.
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(style: StrokeStyle(lineWidth: active ? 1.5 : 1, dash: [5, 3]))
            .foregroundStyle(active ? Color.accentColor : Color.white.opacity(0.45))
            .contentShape(Rectangle())
            .frame(width: max(24, rect.width), height: max(16, rect.height))
            .position(x: rect.midX + translation.width, y: rect.midY + translation.height)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { translation = $0.translation }
                .onEnded { value in
                    let moved = value.translation
                    translation = .zero
                    guard size.width > 0, size.height > 0 else { return }
                    onMove(element, CustomPosition(x: (rect.midX + moved.width) / size.width,
                                                   y: (rect.midY + moved.height) / size.height))
                })
            .help("Drag to place the \(element.label)")
            .accessibilityLabel("\(element.label.capitalized) position")
    }
}
