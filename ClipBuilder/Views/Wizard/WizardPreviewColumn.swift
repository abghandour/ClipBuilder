import SwiftUI

/// A sibling of the settings form, so the scene stays visible while editing.
struct WizardPreviewColumn: View {
    @Environment(AppStore.self) private var store
    let scenes: [SceneRecord]
    let options: WizardOptions
    let profile: BrandProfile
    /// Pinned under the preview: Express puts its run summary and Generate here.
    var footer: AnyView? = nil
    @State private var model: WizardPreviewModel
    @State private var reloadID = 0

    init(scenes: [SceneRecord], options: WizardOptions, profile: BrandProfile, thumbnails: ThumbnailService,
         footer: AnyView? = nil) {
        self.scenes = scenes
        self.options = options
        self.profile = profile
        self.footer = footer
        _model = State(initialValue: WizardPreviewModel(thumbnails: thumbnails))
    }

    private struct ContentKey: Equatable {
        var scene: SceneRecord?
        var generation: Int
        var transcriptVersion: Int
        var people: [PersonRecord]
        var language: String?
        var tagStyle: TagStyle
        var reloadID: Int
        var cameraFocus: String
        var canvasAspect: Double
    }

    private var contentKey: ContentKey {
        ContentKey(scene: model.selectedScene, generation: store.profileGeneration,
            transcriptVersion: store.transcriptCountsVersion, people: store.people,
            language: options.captionLanguage, tagStyle: profile.tagStyle(id: options.nameTagStyleID), reloadID: reloadID,
            cameraFocus: options.podcastFraming == .original ? WizardCameraFocus.original : options.highlightFraming?.rawValue ?? "",
            canvasAspect: options.renderSettings.aspectRatio)
    }

    private func key(overlayTexts: [String]) -> PreviewKey? {
        guard let record = model.selectedScene else { return nil }
        return PreviewKey(options: options, scene: record, profile: profile,
                          contentRevision: model.contentRevision, overlayTexts: overlayTexts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceS) {
                    title
                    Spacer(minLength: 0)
                    sceneStepper
                    chromePicker
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    HStack {
                        title
                        Spacer(minLength: 0)
                        chromePicker
                    }
                    sceneStepper
                }
            }
            GeometryReader { available in
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    preview
                        .aspectRatio(options.renderSettings.aspectRatio, contentMode: .fit)
                        .frame(maxHeight: max(120, available.size.height - 88), alignment: .top)
                    if let error = model.error {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Retry preview") { reloadID += 1 }
                            .lineLimit(1).fixedSize()
                    }
                    if let warning = model.scene?.framingWarning {
                        Text(warning).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("One scene with the current Picture and Overlays settings. Position choices set to Auto are resolved for this scene.")
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
        .task(id: contentKey) {
            model.cancel()
            await model.loadScene(model.selectedScene, database: store.database, people: store.people,
                                  language: options.captionLanguage, tagStyleID: options.nameTagStyleID, profile: profile, options: options)
            if !Task.isCancelled { refresh() }
        }
        // Typing replacements is deliberately not an invalidation trigger.
        // The actual cache key includes the text snapshot used by the next render.
        .onChange(of: key(overlayTexts: []), initial: true) { _, _ in refresh() }
        .onDisappear { model.cancel() }
    }

    private var title: some View {
        Text("Preview").font(.headline).lineLimit(1).fixedSize()
    }

    private var chromePicker: some View {
        PlatformChromePicker().labelStyle(.iconOnly).lineLimit(1).fixedSize()
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
        guard let record = model.selectedScene, model.loadedSceneID == record.id,
              let scene = model.scene, let key = key(overlayTexts: options.fixedOverlayTexts ?? []) else { return }
        model.update(key: key) {
            .init(scene: scene, options: options, profile: profile, templates: model.templates, frameData: Data())
        }
    }
}
