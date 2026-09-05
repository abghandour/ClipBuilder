import SwiftUI

struct TimelineRowView: View {
    let timeline: TimelineRecord
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Theme.spaceM) {
            Group {
                if let path = timeline.thumbnailPath {
                    VideoThumbnail(url: URL(fileURLWithPath: path), time: 0.5)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 84, height: 46)
            .clipShape(.rect(cornerRadius: Theme.mediaRadius))

            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                HStack(spacing: Theme.spaceS) {
                    Text(timeline.name)
                        .bold()
                        .lineLimit(1)
                    Text(timeline.isWizard ? "Wizard" : "Builder")
                        .font(.caption.bold())
                        .foregroundStyle(timeline.isWizard ? .green : .purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (timeline.isWizard ? Color.green : Color.purple).opacity(0.16),
                            in: .rect(cornerRadius: Theme.chipRadius))
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(timeline.duration.timecode)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 60)

            Button(timeline.isWizard ? "Open in Builder" : "Open", action: onOpen)

            Menu("Timeline Actions", systemImage: "ellipsis") {
                Button("Rename…", systemImage: "pencil", action: onRename)
                    .disabled(timeline.isWizard)
                Button("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
            .labelStyle(.iconOnly)
        }
        .padding(.vertical, Theme.spaceS)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Open", onOpen)
    }

    private var detail: String {
        let edited = timeline.editedDate?.formatted(.relative(presentation: .named)) ?? "recently"
        if timeline.isWizard {
            return "Wizard run · \(timeline.clipCount) clips · rendered \(edited)"
        }
        return "\(timeline.clipCount) clips · edited \(edited)"
    }
}
