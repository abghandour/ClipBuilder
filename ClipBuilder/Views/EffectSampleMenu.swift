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

    private var choices: [SourceChoice] {
        sources.map {
            SourceChoice(
                id: $0.url.path, url: $0.url, filename: $0.filename,
                detail: "\($0.typeLabel ?? "Unknown type") · \($0.duration.timecode)", duration: $0.duration)
        }
    }
    private var selection: SourceChoice? {
        guard let selectedURL else { return nil }
        return choices.first { $0.url == selectedURL } ?? SourceChoice(otherFile: selectedURL)
    }

    var body: some View {
        HStack(spacing: Theme.spaceS) {
            Text(title).font(.callout).lineLimit(1).fixedSize()
            SourcePickerButton(
                title: accessibilityTitle, choices: choices, selection: selection, placeholder: "Built-in test card",
                caption: "Choose a project source for the preview.",
                emptyMessage: projectHasSources ? "No sources on this Mac" : "No sources in this project",
                actions: [
                    SourceAction(title: "Other file…", systemImage: "folder", action: otherFile),
                    SourceAction(title: "Built-in test card", systemImage: "film", isCurrent: selectedURL == nil) { select(nil) },
                ]
            ) { select($0.url) }
            .help(selectedURL?.path ?? "Choose a project source or another file for the preview")
        }
        .controlSize(.small)
    }
}
