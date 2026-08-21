import SwiftUI
import UniformTypeIdentifiers

/// Overlay Wizard: hand it a reference frame (a screenshot of a reel whose
/// look you like) and the AI extracts the overlay design — text recreated as
/// native text items, logos/badges cropped into the Images library — as a
/// new overlay template. Footage content (people, background) is discarded.
struct OverlayWizardSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Called with the created template's name so the list can select it.
    var onCreated: (String) -> Void = { _ in }

    @State private var imageURL: URL?
    @State private var preview: NSImage?
    @State private var showImporter = false
    @State private var isDropTargeted = false
    @State private var isRunning = false
    @State private var statusLine = ""
    @State private var errorMessage: String?
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

            HStack {
                ModelPicker(title: "Model", task: "overlay", selection: $modelTag,
                            imageCapableOnly: true, availableProviders: availableProviders)
                    .fixedSize()
                Spacer()
            }

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusLine.isEmpty ? "Reading the overlay design…" : statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isRunning ? "Extracting…" : "Extract Overlay") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(imageURL == nil || isRunning)
            }
        }
        .padding(20)
        .frame(width: 460)
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
        let (provider, model) = ModelPicker.parse(modelTag)
        isRunning = true
        errorMessage = nil
        Task {
            do {
                let name = try await store.extractOverlayTemplate(
                    from: imageURL, provider: provider, model: model) { message in
                    Task { @MainActor in statusLine = message }
                }
                onCreated(name)
                dismiss()
            } catch {
                errorMessage = error.userMessage
            }
            isRunning = false
        }
    }
}
