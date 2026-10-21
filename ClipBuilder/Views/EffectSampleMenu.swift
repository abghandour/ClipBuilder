import SwiftUI

/// Visible on both browsers, even before any previews have been rendered.
struct EffectSampleMenu: View {
    let title: String
    let accessibilityTitle: String
    let sources: [EffectSamplePicker.Source]
    let projectHasSources: Bool
    let selectedURL: URL?
    let select: (URL?) -> Void
    let otherFile: () -> Void

    var body: some View {
        HStack(spacing: Theme.spaceS) {
            Text(title).font(.callout).lineLimit(1).fixedSize()
            Menu {
                if sources.isEmpty {
                    Button(projectHasSources ? "No sources on this Mac" : "No sources in this project") { }
                        .disabled(true)
                }
                ForEach(sources) { source in
                    Button {
                        select(source.url)
                    } label: {
                        HStack(spacing: Theme.spaceS) {
                            VideoThumbnail(url: source.url, time: min(1, source.duration / 2), cornerRadius: 3)
                                .frame(width: 32, height: 20)
                                .accessibilityHidden(true)
                            Text("\(source.filename) · \(source.duration.timecode)")
                                .lineLimit(1).fixedSize()
                            if source.url == selectedURL {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .accessibilityLabel("\(source.filename), \(source.duration.timecode)")
                }
                Divider()
                Button("Other file…", systemImage: "folder", action: otherFile)
                Button("Built-in test card", systemImage: "film") { select(nil) }
            } label: {
                HStack(spacing: Theme.spaceS) {
                    if let selectedURL {
                        VideoThumbnail(url: selectedURL, time: 0, cornerRadius: 3)
                            .frame(width: 32, height: 20)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "film")
                    }
                    Text(selectedURL?.lastPathComponent ?? "Built-in test card")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 220, alignment: .leading)
            }
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue(selectedURL?.lastPathComponent ?? "Built-in test card")
            .help(selectedURL?.path ?? "Choose a project source or another file for the preview")
        }
        .controlSize(.small)
    }
}
