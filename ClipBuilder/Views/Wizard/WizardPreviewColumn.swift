import SwiftUI

/// An element the user can drag to a new place in the preview.
enum PreviewElement: Hashable, Sendable {
    case caption(slot: String?)
    /// The tagged person's key; a drag sets that person's own position.
    case nameTag(person: String?)

    var label: String {
        switch self {
        case .caption: "caption"
        case .nameTag: "name tag"
        }
    }
}

/// The rough cut sheet's still: one kept clip at one moment rendered with
/// the sheet's settings, filling its frame, with live handles for the
/// caption, name tags, overlay items and focus frame. The wizard pages'
/// third column only plays the recording (`WizardPlayerColumn`); this is
/// the one place the settings are previewed before a render.
struct WizardPreviewColumn: View {
    @Environment(AppStore.self) private var store
    let scenes: [SceneRecord]
    /// Kept footage; the pinned moment names one of these.
    let clips: [WizardPreviewClip]
    let options: WizardOptions
    let profile: BrandProfile
    var captionOrdinals: [String: Int]? = nil
    /// Called when the user drops a dragged caption or name tag.
    var onMove: ((PreviewElement, CustomPosition) -> Void)? = nil
    /// Called when the user moves or resizes one component of the overlay
    /// design to a box in design coordinates, as canvas fractions.
    var onPlaceOverlay: ((OverlayComponent, CGRect) -> Void)? = nil
    /// Non-nil while the focus frame can be placed (the sheet's Picture tab).
    var onPlaceFocusFrame: ((FreeCropRect?) -> Void)? = nil
    /// The clip and moment the still shows.
    let pinned: WizardPreviewMoment
    @State private var model: WizardPreviewModel
    @State private var reloadID = 0
    @State private var loadedContentKey: ContentKey?

    init(scenes: [SceneRecord], clips: [WizardPreviewClip], options: WizardOptions, profile: BrandProfile,
         thumbnails: ThumbnailService, captionOrdinals: [String: Int]? = nil,
         onMove: ((PreviewElement, CustomPosition) -> Void)? = nil,
         onPlaceOverlay: ((OverlayComponent, CGRect) -> Void)? = nil,
         onPlaceFocusFrame: ((FreeCropRect?) -> Void)? = nil,
         pinned: WizardPreviewMoment) {
        self.pinned = pinned
        self.scenes = scenes
        self.clips = clips
        self.options = options
        self.profile = profile
        self.captionOrdinals = captionOrdinals
        self.onMove = onMove
        self.onPlaceOverlay = onPlaceOverlay
        self.onPlaceFocusFrame = onPlaceFocusFrame
        _model = State(initialValue: WizardPreviewModel(thumbnails: thumbnails))
    }

    private var currentClip: WizardPreviewClip? { clips.first { $0.id == pinned.clipID } }

    /// The scene the still is read from.
    private var previewRecord: SceneRecord? { currentClip?.scene ?? model.selectedScene }

    private var previewTime: Double? {
        guard let clip = currentClip else { return nil }
        return min(clip.end, max(clip.start, pinned.time))
    }

    private struct ContentKey: Equatable {
        var scene: SceneRecord?
        var generation: Int
        var transcriptVersion: Int
        var people: [PersonRecord]
        /// Bumped when a tag field (Role, Team, handle, position) is saved for a person.
        var tagFieldsVersion: Int
        var language: String?
        var tagStyle: TagStyle
        var reloadID: Int
        var framing: Framing
        var canvasAspect: Double
        var clipID: String?
        var brollCuts: [BRollCut]?
        var chosenSubject: Framing.Subject?
        /// The kept range the framing is planned over (a trim changes it, not the id).
        var rangeStart: Double?
        var rangeEnd: Double?
        /// The moment, rounded so sub-frame jitter does not reload.
        var time: Double?
    }

    /// What the recording-wide part of a scene load depends on; the model
    /// keeps that part across moments while this stays the same.
    private var snapshotKey: String {
        "\(previewRecord?.videoID ?? -1)|\(options.effectiveCaptionLanguage ?? "")|\(store.transcriptCountsVersion)|"
            + "\(store.personTagFieldsVersion)|\(store.profileGeneration)|\(options.nameTagStyleID ?? "")|\(reloadID)|\(store.videosVersion)|\(store.scenesVersion)"
    }

    private var contentKey: ContentKey {
        ContentKey(scene: previewRecord, generation: store.profileGeneration,
            transcriptVersion: store.transcriptCountsVersion, people: store.people,
            tagFieldsVersion: store.personTagFieldsVersion, language: options.effectiveCaptionLanguage, tagStyle: profile.tagStyle(id: options.nameTagStyleID), reloadID: reloadID,
            framing: WizardPreviewFraming.planningFraming(options.requestedFraming,
                videoType: store.videos.first { $0.id == previewRecord?.videoID }?.type),
            canvasAspect: options.renderSettings.aspectRatio,
            clipID: currentClip?.id, brollCuts: currentClip?.brollCuts, chosenSubject: currentClip?.chosenSubject,
            rangeStart: currentClip?.start, rangeEnd: currentClip?.end,
            time: previewTime.map { ($0 * 20).rounded() / 20 })
    }

    private func key(overlayTexts: [String]) -> PreviewKey? {
        guard let record = previewRecord else { return nil }
        return PreviewKey(options: options, scene: record, profile: profile,
                          contentRevision: model.contentRevision, overlayTexts: overlayTexts, time: previewTime,
                          shownSpeakers: Set(speakerKeys), captionOrdinals: captionOrdinals,
                          chosenSubject: currentClip?.chosenSubject)
    }

    var body: some View {
        preview
            .onChange(of: scenes, initial: true) { _, values in model.setScenes(values) }
            .task(id: contentKey) {
                let requestedContent = contentKey
                loadedContentKey = nil
                model.cancel()
                // The playhead under the still changes the key many times a
                // second while it is dragged; load once the hand pauses.
                if contentKey.time != nil {
                    try? await Task.sleep(for: .milliseconds(120))
                    if Task.isCancelled { return }
                }
                await model.loadScene(previewRecord, database: store.database, people: store.people,
                                      language: options.effectiveCaptionLanguage, tagStyleID: options.nameTagStyleID, profile: profile, options: options,
                                      range: currentClip?.range, time: previewTime, snapshotKey: snapshotKey,
                                      reviewedBRoll: currentClip?.brollCuts, chosenSubject: currentClip?.chosenSubject)
                if !Task.isCancelled, model.isSceneCurrent {
                    loadedContentKey = requestedContent
                }
            }
            // Use the current view's options: controls may have changed while
            // the content task was loading with its earlier options snapshot.
            .onChange(of: loadedContentKey) { _, _ in refresh() }
            // The cache key includes the text snapshot used by the next render.
            .onChange(of: key(overlayTexts: []), initial: true) { _, _ in refresh() }
            // Typed replacement texts re-render after a short pause.
            .task(id: options.fixedOverlayTexts ?? []) {
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { refresh() }
            }
            .onDisappear { model.cancel() }
    }

    private var resolvedOrdinals: [String: Int] {
        captionOrdinals ?? model.scene?.resolvedCaptionOrdinals ?? [:]
    }

    private var speakerKeys: [String] {
        guard let scene = model.scene else { return [] }
        return scene.roster.keys.filter { scene.speakingPeople.contains($0) }.sorted {
            let lhs = resolvedOrdinals[$0] ?? Int.max, rhs = resolvedOrdinals[$1] ?? Int.max
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
    }

    private var preview: some View {
        Color.black
            .overlay {
                if let error = model.error {
                    VStack(spacing: Theme.spaceS) {
                        Text(error).font(.caption).foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Button("Retry preview") { reloadID += 1 }
                            .lineLimit(1).fixedSize()
                    }
                    .padding(Theme.spaceM)
                } else if let image = model.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .accessibilityLabel("Preview with the current settings")
                }
            }
            .overlay {
                if model.selectedScene != nil {
                    GeometryReader { geometry in
                        // The sheet's player shades the unsafe zones itself so they stay during playback.
                        PlatformChromeLayer(size: geometry.size,
                                            safeAreaSettings: options.renderSettings.platformSafeArea,
                                            safeAreaOnly: nil)
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if let onMove, let layout = model.layout, model.image != nil {
                    GeometryReader { geometry in
                        PreviewHandlesLayer(layout: layout, canvas: CGSize(width: options.renderSettings.width,
                                                                           height: options.renderSettings.height),
                                            size: geometry.size, ordinals: resolvedOrdinals,
                                            revealMarkers: false, onMove: onMove, onPlaceOverlay: onPlaceOverlay)
                    }
                }
            }
            .overlay {
                if options.requestedFraming.subject != .layout, let sourceRect = model.layout?.sourceRect,
                   model.image != nil, let scene = model.scene {
                    GeometryReader { geometry in
                        focusHandle(sourceRect: sourceRect, sourceSize: scene.sourceSize, size: geometry.size)
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

    @ViewBuilder
    private func focusHandle(sourceRect: CGRect, sourceSize: CGSize, size: CGSize) -> some View {
        let framing = options.requestedFraming
        let canvas = CGSize(width: options.renderSettings.width, height: options.renderSettings.height)
        let scale = min(size.width / canvas.width, size.height / canvas.height)
        let source = CGRect(x: (size.width - canvas.width * scale) / 2 + sourceRect.minX * scale,
            y: (size.height - canvas.height * scale) / 2 + sourceRect.minY * scale,
            width: sourceRect.width * scale, height: sourceRect.height * scale)
        let frame = framing.focusFrame ?? FocusFrame.initial(framing: framing, sourceSize: sourceSize,
            canvasAspect: options.renderSettings.aspectRatio)
        let rect = CGRect(x: source.minX + frame.xFrac * source.width, y: source.minY + frame.yFrac * source.height,
            width: frame.wFrac * source.width, height: frame.hFrac * source.height)
        if framing.focusFrame != nil, onPlaceFocusFrame == nil {
            Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false).accessibilityLabel("Focus frame")
        }
        if let onPlaceFocusFrame, source.width > 0, source.height > 0 {
            // Account for a stored non-aspect crop's nonuniform mapping as well as a normal cover transform.
            let aspect: CGFloat? = FocusFrame.handleAspectLocked(framing: framing)
                ? CGFloat(source.height / source.width * sourceSize.width / sourceSize.height / options.renderSettings.aspectRatio) : nil
            PreviewComponentHandle(rect: rect, aspect: aspect, size: size, bounds: source, allowsZoom: true) { placed in
                onPlaceFocusFrame(FocusFrame.resolved(FreeCropRect(xFrac: (placed.minX - source.minX) / source.width,
                    yFrac: (placed.minY - source.minY) / source.height,
                    wFrac: placed.width / source.width, hFrac: placed.height / source.height)))
            }
        }
    }

    private func refresh() {
        // This also closes the gap before the content task starts (or while
        // a moment change is debounced): the retained scene belongs to the old key.
        guard loadedContentKey == contentKey, model.isSceneCurrent,
              let record = previewRecord, model.loadedSceneID == record.id,
              var scene = model.scene, let key = key(overlayTexts: options.fixedOverlayTexts ?? []) else { return }
        scene.captionOrdinals = captionOrdinals ?? scene.captionOrdinals
        model.update(key: key) {
            .init(scene: scene, options: options, profile: profile, templates: model.templates,
                  frameData: Data(), shownSpeakers: speakerKeys.isEmpty ? nil : Set(speakerKeys))
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
    let ordinals: [String: Int]
    let revealMarkers: Bool
    let onMove: (PreviewElement, CustomPosition) -> Void
    var onPlaceOverlay: ((OverlayComponent, CGRect) -> Void)? = nil

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
            ForEach(Array(layout.tags.enumerated()), id: \.offset) { index, rect in
                let person = layout.tagKeys.indices.contains(index) ? layout.tagKeys[index] : nil
                PreviewHandle(element: .nameTag(person: person), rect: viewRect(rect), size: size, onMove: onMove)
            }
            ForEach(Array(layout.captions.enumerated()), id: \.element.personKey) { _, caption in
                let slot = caption.personKey.flatMap { ordinals[$0] }.map(CaptionSpeakerOrder.slot)
                PreviewHandle(element: .caption(slot: slot), rect: viewRect(caption.rect), size: size,
                              name: caption.name, isTalking: caption.isTalking, revealMarker: revealMarkers, onMove: onMove)
            }
            if let onPlaceOverlay {
                ForEach(layout.overlayComponents, id: \.component) { box in
                    PreviewComponentHandle(component: box.component, rect: viewRect(box.rect), aspect: box.aspect, size: size) { placed in
                        guard scale > 0, canvas.width > 0, canvas.height > 0 else { return }
                        // Back to canvas pixels, minus the legacy whole-design drag, then to fractions.
                        let canvasRect = CGRect(x: (placed.minX - origin.x) / scale - layout.overlayShift.x,
                                                y: (placed.minY - origin.y) / scale - layout.overlayShift.y,
                                                width: placed.width / scale, height: placed.height / scale)
                        onPlaceOverlay(box.component, CGRect(x: canvasRect.minX / canvas.width, y: canvasRect.minY / canvas.height,
                                                             width: canvasRect.width / canvas.width, height: canvasRect.height / canvas.height))
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// One component of the overlay design: a drag inside the outline moves it,
/// grips on the corners and edges resize it. Images keep their aspect.
private struct PreviewComponentHandle: View {
    var component: OverlayComponent? = nil
    private var label: String { component?.label ?? "focus frame" }
    /// The component's rendered box in the preview view's coordinates.
    let rect: CGRect
    /// Height over width to keep while resizing; nil = free.
    var aspect: CGFloat? = nil
    /// The preview view's size; the box stays inside it.
    let size: CGSize
    /// Focus frames are constrained to the source rather than to the cropped canvas.
    var bounds: CGRect? = nil
    /// Only the focus frame responds to wheel/pinch zoom and insets canvas-edge grips.
    var allowsZoom = false
    /// The box the component was dropped at, in the preview view's coordinates.
    let onPlace: (CGRect) -> Void
    @State private var live: CGRect?
    @State private var hovering = false
    @State private var hoveredGrip: Grip?
    @State private var zoomTask: Task<Void, Never>?
    @State private var dragStart: CGRect?
    @Namespace private var handleCoordinates

    static let minimumWidth: CGFloat = 24
    static let minimumHeight: CGFloat = 12

    enum Grip: CaseIterable, Hashable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

        func point(in rect: CGRect) -> CGPoint {
            let x = movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX
            let y = movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY
            return CGPoint(x: x, y: y)
        }

        var cursor: NSCursor {
            switch self {
            case .left, .right: .resizeLeftRight
            case .top, .bottom: .resizeUpDown
            default: .crosshair
            }
        }

        /// `rect` with the edges this grip holds moved by `translation`; the
        /// opposite edges stay put, the box keeps a minimum size and stays
        /// inside `bounds`. With an `aspect` the height follows the width
        /// (or the width the height, for the top and bottom grips), anchored
        /// on the edges that did not move.
        func resized(_ rect: CGRect, by translation: CGSize, in bounds: CGSize, aspect: CGFloat?) -> CGRect {
            var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
            if movesLeft { left = min(right - PreviewComponentHandle.minimumWidth, max(0, left + translation.width)) }
            if movesRight { right = max(left + PreviewComponentHandle.minimumWidth, min(bounds.width, right + translation.width)) }
            if movesTop { top = min(bottom - PreviewComponentHandle.minimumHeight, max(0, top + translation.height)) }
            if movesBottom { bottom = max(top + PreviewComponentHandle.minimumHeight, min(bounds.height, bottom + translation.height)) }
            guard let aspect, aspect > 0 else {
                return CGRect(x: left, y: top, width: right - left, height: bottom - top)
            }
            if movesLeft || movesRight {
                let height = (right - left) * aspect
                if movesTop { top = bottom - height } else if movesBottom { bottom = top + height } else {
                    let mid = rect.midY
                    top = mid - height / 2
                    bottom = mid + height / 2
                }
            } else {
                let width = (bottom - top) / aspect
                let mid = rect.midX
                left = mid - width / 2
                right = mid + width / 2
            }
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    /// `rect` moved by `translation`, kept inside the preview.
    private var movementBounds: CGRect { bounds ?? CGRect(origin: .zero, size: size) }

    private func moved(by translation: CGSize) -> CGRect {
        let rect = dragStart ?? rect
        let box = movementBounds
        let x = min(max(box.minX, rect.minX + translation.width), max(box.minX, box.maxX - rect.width))
        let y = min(max(box.minY, rect.minY + translation.height), max(box.minY, box.maxY - rect.height))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    private func resized(_ grip: Grip, by translation: CGSize) -> CGRect {
        let rect = dragStart ?? rect
        let box = movementBounds
        let local = rect.offsetBy(dx: -box.minX, dy: -box.minY)
        var result = grip.resized(local, by: translation, in: box.size, aspect: aspect)
        if bounds != nil {
            // Keep the locked aspect when a corner reaches a source boundary.
            let factor = min(1, min(box.width / max(1, result.width), box.height / max(1, result.height)))
            result.size = CGSize(width: result.width * factor, height: result.height * factor)
            result.origin.x = min(max(0, result.minX), max(0, box.width - result.width))
            result.origin.y = min(max(0, result.minY), max(0, box.height - result.height))
        }
        return result.offsetBy(dx: box.minX, dy: box.minY)
    }

    private func scale(by factor: CGFloat, debounce: Bool) {
        guard dragStart == nil else { return }
        zoomTask?.cancel()
        zoomTask = nil
        live = PreviewHandleGeometry.scaled(live ?? rect, by: factor, aspect: aspect, bounds: movementBounds,
            minimum: CGSize(width: Self.minimumWidth, height: Self.minimumHeight))
        if debounce {
            zoomTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                finishZoom()
            }
        }
    }

    private func finishZoom() {
        zoomTask?.cancel()
        zoomTask = nil
        guard dragStart == nil, let final = live else { return }
        live = nil
        if final != rect { onPlace(final) }
    }

    private func beginDrag() {
        guard dragStart == nil else { return }
        zoomTask?.cancel()
        zoomTask = nil
        // A drag can take over a wheel edit before its debounce commits.
        dragStart = live ?? rect
    }

    private func resetInteraction() {
        zoomTask?.cancel()
        zoomTask = nil
        live = nil
        dragStart = nil
    }

    var body: some View {
        let current = live ?? rect
        let visible = CGRect(origin: .zero, size: size)
        let displayed = allowsZoom ? PreviewHandleGeometry.insetForDisplay(current, visible: visible, inset: Theme.spaceS) : current
        let active = live != nil || hovering || hoveredGrip != nil
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(active ? Color.accentColor : Color.white.opacity(0.4), lineWidth: active ? 1.5 : 1)
                .contentShape(Rectangle())
                .frame(width: allowsZoom ? displayed.width : max(Self.minimumWidth, displayed.width),
                       height: allowsZoom ? displayed.height : max(Self.minimumHeight, displayed.height))
                .position(x: displayed.midX, y: displayed.midY)
                .onHover { inside in
                    hovering = inside
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(handleCoordinates))
                    .onChanged { value in
                        beginDrag()
                        live = moved(by: value.translation)
                    }
                    .onEnded { value in
                        let final = moved(by: value.translation)
                        resetInteraction()
                        onPlace(final)
                    })
                .help("Drag to move the \(label); drag an edge or corner to resize it")
                .accessibilityLabel("\(label.capitalized) position")
            ForEach(Grip.allCases, id: \.self) { grip in
                let point = grip.point(in: displayed)
                Rectangle()
                    .fill(active ? Color.accentColor : Color.white.opacity(0.7))
                    .frame(width: 7, height: 7)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 0.5))
                    .contentShape(Rectangle().inset(by: -4))
                    .position(point)
                    .onHover { inside in
                        if inside {
                            hoveredGrip = grip
                            grip.cursor.push()
                        } else if hoveredGrip == grip {
                            hoveredGrip = nil
                            NSCursor.pop()
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(handleCoordinates))
                        .onChanged { value in
                            beginDrag()
                            live = resized(grip, by: value.translation)
                        }
                        .onEnded { value in
                            let final = resized(grip, by: value.translation)
                            resetInteraction()
                            onPlace(final)
                        })
                    .accessibilityLabel("\(label.capitalized) resize")
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: handleCoordinates)
        .background {
            if allowsZoom {
                PreviewFocusZoomEvents(onScroll: { scale(by: $0, debounce: true) }, onMagnify: { factor, ended in
                    scale(by: factor, debounce: false)
                    if ended { finishZoom() }
                })
            }
        }
        .onChange(of: rect) { resetInteraction() }
        .onChange(of: bounds) { resetInteraction() }
        .onChange(of: size) { resetInteraction() }
        .onChange(of: aspect) { resetInteraction() }
        .onDisappear { resetInteraction() }
    }
}

private struct PreviewHandle: View {
    let element: PreviewElement
    /// The element's rect in the preview view's coordinates.
    let rect: CGRect
    /// The preview view's size, which the drop maps to canvas fractions.
    let size: CGSize
    var name: String? = nil
    var isTalking = false
    /// The owner asks every marker to show for a moment (a chip changed).
    var revealMarker = false
    let onMove: (PreviewElement, CustomPosition) -> Void
    @State private var translation = CGSize.zero
    @State private var hovering = false
    /// Keeps the marker up for a couple of seconds after the pointer leaves.
    @State private var lingering = false
    @State private var lingerID = 0

    var body: some View {
        let active = hovering || translation != .zero
        // A faint outline says the element can be moved; it brightens on hover.
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(style: StrokeStyle(lineWidth: active ? 1.5 : 1, dash: [5, 3]))
            .foregroundStyle(active ? Color.accentColor : Color.white.opacity(0.45))
            .contentShape(Rectangle())
            .frame(width: max(24, rect.width), height: max(16, rect.height))
            .overlay(alignment: .topLeading) {
                // The marker sits just above the outline so it never covers the
                // words, and only while hovered, just after, or on a chip change.
                if let name, revealMarker || hovering || lingering || translation != .zero {
                    Text(name).font(.caption2).lineLimit(1).fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(isTalking ? Color.accentColor : Color.secondary, in: Capsule())
                        .alignmentGuide(.top) { $0[.bottom] + 2 }
                }
            }
            .position(x: rect.midX + translation.width, y: rect.midY + translation.height)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.openHand.push() } else { NSCursor.pop(); linger() }
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
            .accessibilityLabel("\(name ?? element.label.capitalized) position")
    }

    private func linger() {
        lingerID += 1
        let id = lingerID
        lingering = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            if lingerID == id { lingering = false }
        }
    }
}
