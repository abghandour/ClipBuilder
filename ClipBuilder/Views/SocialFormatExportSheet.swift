import SwiftUI
import UniformTypeIdentifiers

struct SocialFormatExportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let video: GeneratedVideoRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Instagram Formats").font(.headline)
            Text(video.filename).foregroundStyle(.secondary)
            GroupBox("Video") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Story · 9:16", action: { exportVideo(.portrait1080, suffix: "story") })
                    Button("Feed Post · 1:1", action: { exportVideo(.square1080, suffix: "feed-square") })
                    Button("Feed Post · 4:5", action: { exportVideo(.feedPortrait1080, suffix: "feed-portrait") })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Carousel") {
                Button(
                    "Export 5 Best-frame Stills…", systemImage: "rectangle.stack",
                    action: exportCarousel)
            }
            HStack {
                Spacer()
                Button("Done", action: dismiss.callAsFunction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .appJobSetupPresentation()
    }

    private func exportVideo(_ preset: RenderPreset, suffix: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(video.url.deletingPathExtension().lastPathComponent)-\(suffix).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = store
        let video = video
        var settings = store.activeProfile.defaultRenderSettings
        settings.preset = preset
        let renderSettings = settings
        store.jobs.start(.socialExport, title: "Export \(preset.label)",
                         project: store.activeProject, profileGeneration: store.profileGeneration) { log in
            log("Exporting \(video.filename)…")
            try await SocialFormatExporter().exportVideo(source: video.url, settings: renderSettings, destination: url)
            return .socialExport(urls: [url])
        }
        dismiss()
    }

    private func exportCarousel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let root = panel.url else { return }
        let folder = root.appending(
            path: "\(video.url.deletingPathExtension().lastPathComponent)-carousel",
            directoryHint: .isDirectory)
        let store = store
        let video = video
        store.jobs.start(.socialExport, title: "Export Carousel — \(video.filename)",
                         project: store.activeProject, profileGeneration: store.profileGeneration) { log in
            log("Extracting carousel frames…")
            let files = try await SocialFormatExporter().exportCarousel(source: video.url, duration: video.duration, directory: folder)
            return .socialExport(urls: files)
        }
        dismiss()
    }
}
