import SwiftUI
import UniformTypeIdentifiers

/// Overlay Wizard: hand it a reference frame (a screenshot of a reel whose
/// look you like) and the AI extracts the overlay design — text recreated as
/// native text items, logos/badges cropped into the Images library — as a
/// new overlay template. Footage content (people, background) is discarded.
struct OverlayWizardSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var errorMessage: String?
    @State private var imageURL: URL?
    @State private var preview: NSImage?
    @State private var showImporter = false
    @State private var isDropTargeted = false
    // Model choice, dispatcher-style: configured task routing is the seed.
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overlay Wizard")
                .font(.title3.bold())
            Text("Drop a frame from a reel whose overlay style you like. The AI recreates its captions, name plates, and logos as a reusable overlay template — everything else in the image is discarded.")
                .font(.callout)
                .foregroundStyle(.secondary)

            dropZone
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
                Button("Extract Overlay") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(imageURL == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .appJobSetupPresentation()
        .modalCloseButton { dismiss() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { setImage(url) }
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
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: isDropTargeted ? 3 : 1, dash: [6]))
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Drop an image here, or")
                        .foregroundStyle(.secondary)
                    Button("Choose Image…") { showImporter = true }
                }
            }
        }
        .frame(height: 260)
        .contentShape(Rectangle())
        // Always clickable — replacing a loaded image just re-opens the picker.
        .onTapGesture { showImporter = true }
        .help(preview == nil ? "Drop or choose a reference image"
                             : "Click to choose a different image")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            setImage(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private func setImage(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            errorMessage = "Could not read that file as an image."
            return
        }
        errorMessage = nil
        imageURL = url
        preview = image
    }

    private func run() {
        guard let imageURL else { return }
        let store = store
        let generation = store.profileGeneration
        let (provider, model) = ModelPicker.parse(modelTag)
        store.jobs.start(.overlayTemplate, title: "Extract Overlay", project: nil,
                         profileGeneration: generation) { log in
            let name = try await store.extractOverlayTemplate(from: imageURL, provider: provider, model: model, log: log)
            try Task.checkCancellation()
            guard generation == store.profileGeneration else { throw CancellationError() }
            store.createdOverlayName = name
            AssetCatalogChanges.publish()
            log(name)
            return nil
        }
        dismiss()
    }
}
