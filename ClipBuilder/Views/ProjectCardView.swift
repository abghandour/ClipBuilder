import SwiftUI

struct ProjectCardView: View {
    let project: ProjectRecord
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onDrop: ([URL]) -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Theme.spaceM) {
                HStack(spacing: Theme.spaceS) {
                    ForEach(0..<3, id: \.self) { index in
                        Group {
                            if project.thumbnailPaths.indices.contains(index) {
                                VideoThumbnail(url: URL(fileURLWithPath: project.thumbnailPaths[index]), time: 0.5)
                            } else {
                                Rectangle().fill(.quaternary)
                            }
                        }
                        .aspectRatio(4 / 3, contentMode: .fill)
                        .clipShape(.rect(cornerRadius: Theme.mediaRadius))
                    }
                }

                Label(project.name, systemImage: project.isHome ? "house.fill" : "folder")
                    .font(.headline)
                    .foregroundStyle(project.isHome ? Theme.projectTint : .primary)
                    .lineLimit(2)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.spaceM) {
                        ProjectCountLabel(count: project.sourceCount, noun: "source")
                        ProjectCountLabel(count: project.timelineCount, noun: "timeline")
                        ProjectCountLabel(count: project.outputCount, noun: "output")
                    }
                    VStack(alignment: .leading, spacing: Theme.spaceXS) {
                        ProjectCountLabel(count: project.sourceCount, noun: "source")
                        ProjectCountLabel(count: project.timelineCount, noun: "timeline")
                        ProjectCountLabel(count: project.outputCount, noun: "output")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let lastOpenedDate = project.lastOpenedDate {
                    Text("Opened \(lastOpenedDate.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("Not opened yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: .rect(cornerRadius: Theme.cardRadius))
            .contentShape(.rect(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if project.isHome {
                Button("Open Home", systemImage: "house.fill", action: onOpen)
            } else {
                Button("Rename…", systemImage: "pencil", action: onRename)
                Button("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
                Button(
                    project.archived ? "Restore" : "Archive",
                    systemImage: project.archived ? "tray.and.arrow.up" : "archivebox",
                    action: onArchive)
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return !urls.isEmpty
        }
        .accessibilityLabel(
            "\(project.name), \(project.sourceCount) sources, \(project.timelineCount) timelines, \(project.outputCount) outputs"
        )
    }
}

private struct ProjectCountLabel: View {
    let count: Int
    let noun: String

    var body: some View {
        Text("^[\(count) \(noun)](inflect: true)")
    }
}
