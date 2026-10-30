import SwiftUI

/// One pickable video in a source grid: the Express step's cell, reused
/// wherever the app asks for a single source.
struct SourceChoice: Identifiable, Equatable {
    var id: String
    var url: URL
    var filename: String
    /// "Fight · 2:21", "Other file", …
    var detail: String
    var duration: Double

    init(id: String, url: URL, filename: String, detail: String, duration: Double) {
        self.id = id
        self.url = url
        self.filename = filename
        self.detail = detail
        self.duration = duration
    }

    /// Keyed by path, which is what most settings store.
    init(_ video: VideoRecord) {
        self.init(
            id: video.url.path, url: video.url, filename: video.filename,
            detail: "\(video.type?.label ?? "Unknown type") · \(video.duration.timecode)", duration: video.duration)
    }

    /// A file outside the project (chosen through an importer).
    init(otherFile url: URL) {
        self.init(id: url.path, url: url, filename: url.lastPathComponent, detail: "Other file", duration: 0)
    }
}

/// A footer button under the grid: "Other file…", "Built-in test card", "Main recording".
struct SourceAction: Identifiable {
    var id: String { title }
    var title: String
    var systemImage: String
    var isCurrent = false
    var action: () -> Void
}

/// The Express source cell: 16:9 thumbnail, accent border and tick when chosen,
/// file name, then type and duration.
struct SourceCell: View {
    let choice: SourceChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                VideoThumbnail(url: choice.url, time: min(1, choice.duration / 2), cornerRadius: Theme.mediaRadius)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.mediaRadius)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(Theme.spaceXS)
                        }
                    }
                Text(choice.filename)
                    .font(.caption)
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                    .truncationMode(.middle)
                Text(choice.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("\(choice.filename), \(choice.detail)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("Choose \(choice.filename)")
    }
}

/// The grid itself: a caption, the cells, and the footer actions.
struct SourceGrid: View {
    var caption: String
    var choices: [SourceChoice]
    var selectedID: String?
    var emptyMessage = "No sources in this project"
    var select: (SourceChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            if choices.isEmpty {
                FormCaption(emptyMessage)
            } else {
                FormCaption(caption)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: Theme.spaceM, alignment: .top)],
                    spacing: Theme.spaceM
                ) {
                    ForEach(choices) { choice in
                        SourceCell(choice: choice, selected: choice.id == selectedID) { select(choice) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The footer under a source grid: "Other file…", "Built-in test card", "Main recording".
struct SourceActionsRow: View {
    var actions: [SourceAction]

    var body: some View {
        HStack(spacing: Theme.spaceM) {
            ForEach(actions) { action in
                Button(action.title, systemImage: action.systemImage, action: action.action)
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(action.isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            }
            Spacer(minLength: 0)
        }
    }
}

/// A compact button (thumbnail, file name, chevron) that opens the source
/// grid in a popover. Picking a cell or a footer action closes it.
struct SourcePickerButton: View {
    var title: String
    var choices: [SourceChoice]
    /// The current pick, which may be a file outside `choices`.
    var selection: SourceChoice?
    var placeholder: String
    var placeholderImage = "film"
    var caption = "Choose one video."
    var emptyMessage = "No sources in this project"
    var actions: [SourceAction] = []
    var select: (SourceChoice) -> Void
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: Theme.spaceS) {
                if let selection {
                    VideoThumbnail(url: selection.url, time: min(1, selection.duration / 2), cornerRadius: Theme.mediaRadius)
                        .frame(width: 32, height: 20)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: placeholderImage)
                }
                Text(selection?.filename ?? placeholder)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 220, alignment: .leading)
        }
        .accessibilityLabel(title)
        .accessibilityValue(selection?.filename ?? placeholder)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                ScrollView {
                    SourceGrid(caption: caption, choices: choices, selectedID: selection?.id, emptyMessage: emptyMessage) { choice in
                        select(choice)
                        showing = false
                    }
                    .padding(Theme.spaceL)
                }
                .frame(minHeight: 120, maxHeight: 520)
                if !actions.isEmpty {
                    Divider()
                    SourceActionsRow(
                        actions: actions.map { action in
                            var closing = action
                            closing.action = {
                                action.action()
                                showing = false
                            }
                            return closing
                        }
                    )
                    .padding(.horizontal, Theme.spaceL).padding(.vertical, Theme.spaceM)
                }
            }
            .frame(width: 640)
        }
    }
}
