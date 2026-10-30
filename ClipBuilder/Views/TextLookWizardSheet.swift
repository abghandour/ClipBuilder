import SwiftUI
import UniformTypeIdentifiers

/// Which Text Looks tab and style the wizard just created.
struct TextLookSelection: Equatable {
    var tab: TextLooksTab
    var id: String
}

/// Text Look Wizard: hand it a reference image or video (a reel whose text
/// design you like) and the AI recreates the looks you ask for — an overlay
/// template (text as native items, logos cropped into the Images library),
/// a caption style, a name tag style. From a video it also reads the
/// animations: when each element enters and leaves and with which effect,
/// how captions reveal. Footage content (people, background) is discarded.
/// The extraction runs as a background job; this sheet only collects input.
struct TextLookWizardSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var errorMessage: String?
    @State private var fileURL: URL?
    @State private var isVideo = false
    @State private var duration: Double = 0
    @State private var preview: NSImage?
    @State private var loadingPreview = false
    @State private var showImporter = false
    @State private var isDropTargeted = false
    @State private var targets: Set<TextLookExtraction.Target> = [.overlay]
    // Model choice, dispatcher-style: configured task routing is the seed.
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))

    static let movieTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]

    nonisolated static func isMovie(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Text Look Wizard")
                .font(.headline)
            Text("Drop a frame or a short clip from a reel whose text design you like. The AI recreates its overlays, captions and name plates as looks you can reuse; from a video it also copies the animations. Everything else in the file is discarded.")
                .font(.callout)
                .foregroundStyle(.secondary)

            dropZone
            if fileURL != nil { importChoices }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }

            HStack {
                ModelPicker(title: "Model", task: "overlay", selection: $modelTag,
                            imageCapableOnly: true, availableProviders: availableProviders)
                    .fixedSize()
                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(fileURL == nil || targets.isEmpty || loadingPreview)
            }
        }
        .padding(Theme.spaceL)
        .frame(width: 460)
        .appJobSetupPresentation()
        .modalCloseButton { dismiss() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image] + Self.movieTypes) { result in
            if case .success(let url) = result { setFile(url) }
        }
        .task {
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
            if modelTag.isEmpty {
                modelTag = ModelPicker.bestAvailableTag(for: "overlay",
                                                        available: availableProviders)
            }
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.mediaRadius)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: isDropTargeted ? 3 : 1, dash: [6]))
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
                    .overlay(alignment: .bottomTrailing) {
                        if isVideo {
                            MediaBadge(text: "Video · \(String(format: "%.1f", duration)) s")
                                .padding(10)
                        }
                    }
            } else if loadingPreview {
                ProgressView()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Drop an image or video here, or")
                        .foregroundStyle(.secondary)
                    Button("Choose File…") { showImporter = true }
                }
            }
        }
        .frame(height: 220)
        .contentShape(Rectangle())
        // Always clickable — replacing a loaded file just re-opens the picker.
        .onTapGesture { showImporter = true }
        .help(preview == nil ? "Drop or choose a reference image or video"
                             : "Click to choose a different file")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            setFile(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var importChoices: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            SectionLabel("Import")
            ForEach(TextLookExtraction.Target.allCases) { target in
                Toggle(isOn: Binding(
                    get: { targets.contains(target) },
                    set: { on in if on { targets.insert(target) } else { targets.remove(target) } }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.label)
                        Text(target.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            if isVideo {
                Text("The AI watches when each element enters and leaves and picks the closest effect (fade, slide, pop, cut), and reads how captions reveal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setFile(_ url: URL) {
        errorMessage = nil
        preview = nil
        loadingPreview = false
        if Self.isMovie(url) {
            isVideo = true
            fileURL = url
            loadingPreview = true
            Task {
                let seconds = await FFmpeg.duration(of: url)
                let poster = await ThumbnailService.jpegFrame(url: url, at: min(1, seconds / 2), maxDimension: 800)
                guard fileURL == url else { return }
                duration = seconds
                loadingPreview = false
                if let poster, let image = NSImage(data: poster) {
                    preview = image
                } else {
                    errorMessage = "Could not read that file as a video."
                    fileURL = nil
                }
            }
            return
        }
        guard let image = NSImage(contentsOf: url) else {
            errorMessage = "Could not read that file as an image or video."
            fileURL = nil
            return
        }
        isVideo = false
        duration = 0
        fileURL = url
        preview = image
    }

    private func run() {
        guard let fileURL else { return }
        let store = store
        let generation = store.profileGeneration
        let (provider, model) = ModelPicker.parse(modelTag)
        let targets = targets
        store.jobs.start(.overlayTemplate, title: "Text Look Wizard", project: nil,
                         profileGeneration: generation) { log in
            let imported = try await store.importTextLooks(from: fileURL, targets: targets,
                                                           provider: provider, model: model, log: log)
            try Task.checkCancellation()
            guard generation == store.profileGeneration else { throw CancellationError() }
            return .textLooks(imported)
        }
        dismiss()
    }
}
