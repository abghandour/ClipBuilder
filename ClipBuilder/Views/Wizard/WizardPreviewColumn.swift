import SwiftUI

/// An element the user can drag to a new place in the preview.
enum PreviewElement: Hashable, Sendable {
    case caption(slot: String?)
    case nameTag

    var label: String {
        switch self {
        case .caption: "caption"
        case .nameTag: "name tag"
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
    var captionOrdinals: [String: Int]? = nil
    /// Pinned under the preview: Express puts its run summary and Generate here.
    var footer: AnyView? = nil
    /// Called when the user drops a dragged element; the owner stores the
    /// position in its settings and the preview re-renders from them.
    var onMove: ((PreviewElement, CustomPosition) -> Void)? = nil
    /// Called when the user moves or resizes one component of the overlay
    /// design to a box in design coordinates, as canvas fractions; the
    /// owner stores it and the preview re-renders (text wraps to its width,
    /// an image keeps its aspect).
    var onPlaceOverlay: ((OverlayComponent, CGRect) -> Void)? = nil
    @State private var model: WizardPreviewModel
    @State private var reloadID = 0
    @State private var clipIndex = 0
    /// Scrubber position in source seconds; nil shows the middle of the clip.
    @State private var scrubTime: Double?
    /// Chips the user has set for this recording; nil means every speaker.
    @State private var shownSpeakers: Set<String>?
    /// Name markers show briefly after a chip changes or while a caption is hovered.
    @State private var markersRevealed = false
    @State private var markerRevealID = 0

    init(scenes: [SceneRecord], clips: [WizardPreviewClip] = [], options: WizardOptions, profile: BrandProfile,
         thumbnails: ThumbnailService, footer: AnyView? = nil, captionOrdinals: [String: Int]? = nil,
         onMove: ((PreviewElement, CustomPosition) -> Void)? = nil,
         onPlaceOverlay: ((OverlayComponent, CGRect) -> Void)? = nil) {
        self.scenes = scenes
        self.clips = clips
        self.options = options
        self.profile = profile
        self.captionOrdinals = captionOrdinals
        self.footer = footer
        self.onMove = onMove
        self.onPlaceOverlay = onPlaceOverlay
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
        var interviewCuts: Bool
        var interviewPunchIn: String
        var canvasAspect: Double
        var clipID: String?
        /// The kept range the framing is planned over (a trim changes it, not the id).
        var rangeStart: Double?
        var rangeEnd: Double?
        /// Scrubber moment, rounded so a slider's sub-frame jitter does not reload.
        var time: Double?
    }

    /// What the recording-wide part of a scene load depends on; the model
    /// keeps that part across scrubs while this stays the same.
    private var snapshotKey: String {
        "\(previewRecord?.videoID ?? -1)|\(options.effectiveCaptionLanguage ?? "")|\(store.transcriptCountsVersion)|"
            + "\(store.personTagFieldsVersion)|\(store.profileGeneration)|\(options.nameTagStyleID ?? "")|\(reloadID)"
    }

    private var contentKey: ContentKey {
        ContentKey(scene: previewRecord, generation: store.profileGeneration,
            transcriptVersion: store.transcriptCountsVersion, people: store.people,
            tagFieldsVersion: store.personTagFieldsVersion, language: options.effectiveCaptionLanguage, tagStyle: profile.tagStyle(id: options.nameTagStyleID), reloadID: reloadID,
            cameraFocus: options.podcastFraming == .original ? WizardCameraFocus.original : options.highlightFraming?.rawValue ?? "",
            interviewZoom: options.interviewZoom ?? 0, interviewZoomMoves: options.interviewZoomMoves ?? false,
            interviewCuts: options.interviewCuts ?? false,
            interviewPunchIn: (InterviewPunchIn(rawValue: options.interviewPunchIn ?? "") ?? .vip).rawValue,
            canvasAspect: options.renderSettings.aspectRatio,
            clipID: currentClip?.id, rangeStart: currentClip?.start, rangeEnd: currentClip?.end,
            time: previewTime.map { ($0 * 20).rounded() / 20 })
    }

    private func key(overlayTexts: [String]) -> PreviewKey? {
        guard let record = previewRecord else { return nil }
        return PreviewKey(options: options, scene: record, profile: profile,
                          contentRevision: model.contentRevision, overlayTexts: overlayTexts, time: previewTime,
                          shownSpeakers: effectiveShownSpeakers, captionOrdinals: captionOrdinals)
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
                let height = min(max(120, available.size.height - (currentClip == nil ? 88 : 120) - (options.addCaptions && !speakerKeys.isEmpty ? 30 : 0)),
                                 available.size.width / aspect)
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    preview
                        .frame(width: height * aspect, height: height)
                    if let clip = currentClip { scrubber(clip).frame(width: height * aspect) }
                    if options.addCaptions, !speakerKeys.isEmpty { speakerChips.frame(width: height * aspect) }
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
                        + (onMove == nil ? "" : " Drag the caption or a name tag to place it.")
                        + (onPlaceOverlay == nil ? "" : " Drag any part of the overlay to move it, or its edges to resize it."))
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
        .onChange(of: shownSpeakersKey, initial: true) { _, key in
            // While no recording is resolved the key is a placeholder; keep the
            // chips as they are rather than resetting them to "everyone".
            guard previewRecord != nil else { return }
            shownSpeakers = UserDefaults.standard.string(forKey: key).map {
                Set($0.split(separator: "\n").map(String.init))
            }
        }
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
                                  language: options.effectiveCaptionLanguage, tagStyleID: options.nameTagStyleID, profile: profile, options: options,
                                  range: currentClip?.range, time: previewTime, snapshotKey: snapshotKey)
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

    private var shownSpeakersKey: String {
        "preview.shownSpeakers.\(profile.profileName).\(previewRecord?.videoID ?? -1)"
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

    private var talkingSpeaker: String? {
        guard let scene = model.scene else { return nil }
        return CaptionSpeakerColors.personKey(CaptionSpeakerColors.speakerKey(
            for: .init(start: scene.time, end: scene.time.nextUp, text: ""),
            turns: scene.speakerTurns, rows: scene.speakerRows))
    }

    /// The people drawn: the chips when set, else everyone who speaks.
    private var effectiveShownSpeakers: Set<String> { shownSpeakers ?? Set(speakerKeys) }

    private func toggleSpeaker(_ key: String) {
        var shown = effectiveShownSpeakers
        if shown.contains(key) { shown.remove(key) } else { shown.insert(key) }
        shownSpeakers = shown
        if previewRecord != nil {
            UserDefaults.standard.set(shown.sorted().joined(separator: "\n"), forKey: shownSpeakersKey)
        }
        revealMarkers()
    }

    private func revealMarkers() {
        markerRevealID += 1
        let id = markerRevealID
        markersRevealed = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            if markerRevealID == id { markersRevealed = false }
        }
    }

    private var speakerChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.spaceS) {
                ForEach(speakerKeys, id: \.self) { key in
                    let selected = effectiveShownSpeakers.contains(key)
                    Button { toggleSpeaker(key) } label: {
                        Label(model.scene?.roster[key] ?? key, systemImage: selected ? "checkmark.circle.fill" : "circle")
                            .font(.caption).lineLimit(1).fixedSize()
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .tint(selected ? Color.accentColor : Color.secondary)
                    .help(key == talkingSpeaker ? "Talking at this moment. Show or hide this speaker's caption in the preview."
                        : "Show or hide this speaker's caption in the preview")
                    .accessibilityValue(selected ? "Shown" : "Hidden")
                }
            }
        }
        .scrollIndicators(.hidden)
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
                                            size: geometry.size, ordinals: resolvedOrdinals,
                                            revealMarkers: markersRevealed, onMove: onMove, onPlaceOverlay: onPlaceOverlay)
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
              var scene = model.scene, let key = key(overlayTexts: options.fixedOverlayTexts ?? []) else { return }
        scene.captionOrdinals = captionOrdinals ?? scene.captionOrdinals
        model.update(key: key) {
            .init(scene: scene, options: options, profile: profile, templates: model.templates,
                  frameData: Data(), shownSpeakers: speakerKeys.isEmpty ? nil : effectiveShownSpeakers)
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
            ForEach(Array(layout.tags.enumerated()), id: \.offset) { _, rect in
                PreviewHandle(element: .nameTag, rect: viewRect(rect), size: size, onMove: onMove)
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
    let component: OverlayComponent
    /// The component's rendered box in the preview view's coordinates.
    let rect: CGRect
    /// Height over width to keep while resizing; nil = free.
    var aspect: CGFloat? = nil
    /// The preview view's size; the box stays inside it.
    let size: CGSize
    /// The box the component was dropped at, in the preview view's coordinates.
    let onPlace: (CGRect) -> Void
    @State private var live: CGRect?
    @State private var hovering = false
    @State private var hoveredGrip: Grip?

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
    private func moved(by translation: CGSize) -> CGRect {
        let x = min(max(0, rect.minX + translation.width), max(0, size.width - rect.width))
        let y = min(max(0, rect.minY + translation.height), max(0, size.height - rect.height))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    var body: some View {
        let current = live ?? rect
        let active = live != nil || hovering || hoveredGrip != nil
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(active ? Color.accentColor : Color.white.opacity(0.4), lineWidth: active ? 1.5 : 1)
                .contentShape(Rectangle())
                .frame(width: max(Self.minimumWidth, current.width), height: max(Self.minimumHeight, current.height))
                .position(x: current.midX, y: current.midY)
                .onHover { inside in
                    hovering = inside
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { live = moved(by: $0.translation) }
                    .onEnded { value in
                        let final = moved(by: value.translation)
                        live = nil
                        onPlace(final)
                    })
                .help("Drag to move the \(component.label); drag an edge or corner to resize it.")
                .accessibilityLabel("\(component.label.capitalized) position")
            ForEach(Grip.allCases, id: \.self) { grip in
                let point = grip.point(in: current)
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
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { live = grip.resized(rect, by: $0.translation, in: size, aspect: aspect) }
                        .onEnded { value in
                            let final = grip.resized(rect, by: value.translation, in: size, aspect: aspect)
                            live = nil
                            onPlace(final)
                        })
                    .accessibilityLabel("\(component.label.capitalized) resize")
            }
        }
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
