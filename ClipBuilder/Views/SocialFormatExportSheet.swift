import SwiftUI
import UniformTypeIdentifiers

struct SocialFormatExportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let video: GeneratedVideoRecord

    @State private var isExporting = false
    @State private var status = ""
    private let exporter = SocialFormatExporter()

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
            if isExporting { ProgressView() }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Done", action: dismiss.callAsFunction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .disabled(isExporting)
    }

    private func exportVideo(_ preset: RenderPreset, suffix: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(video.url.deletingPathExtension().lastPathComponent)-\(suffix).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        status = "Exporting \(preset.label)…"
        Task {
            do {
                var settings = store.activeProfile.defaultRenderSettings
                settings.preset = preset
                try await exporter.exportVideo(source: video.url, settings: settings, destination: url)
                status = "Exported \(url.lastPathComponent)"
            } catch { store.presentError("Could not export format", error) }
            isExporting = false
        }
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
        isExporting = true
        status = "Extracting carousel frames…"
        Task {
            do {
                let files = try await exporter.exportCarousel(
                    source: video.url,
                    duration: video.duration,
                    directory: folder)
                status = "Exported \(files.count) slides to \(folder.path)"
            } catch { store.presentError("Could not export carousel", error) }
            isExporting = false
        }
    }
}
