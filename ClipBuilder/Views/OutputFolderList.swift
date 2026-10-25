import SwiftUI

/// The Outputs screen's left column: a combo picks one group of folders
/// (Smart, By Date, By Source, By Batch), like the People screen's role
/// picker, and the list below shows only that group.
struct OutputFolderList: View {
    let folders: [OutputFolder]
    @Binding var selection: String?

    @AppStorage("outputs.folderSection") private var sectionRaw = OutputFolder.Section.smart.rawValue

    /// Groups with at least one folder; Smart is always offered.
    private var availableSections: [OutputFolder.Section] {
        OutputFolder.Section.allCases.filter { section in
            section == .smart || folders.contains { $0.section == section }
        }
    }

    private var section: OutputFolder.Section {
        let stored = OutputFolder.Section(rawValue: sectionRaw) ?? .smart
        return availableSections.contains(stored) ? stored : .smart
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Group", selection: Binding(get: { section }, set: { sectionRaw = $0.rawValue })) {
                ForEach(availableSections, id: \.self) { section in
                    Label {
                        Text(section.rawValue)
                    } icon: {
                        Image(systemName: section.symbol)
                    }
                    .tag(section)
                }
            }
            .labelsHidden()
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("Show the smart folders, or the outputs grouped by date, source or batch")
            Divider()
            List(selection: $selection) {
                ForEach(folders.filter { $0.section == section }) { folder in
                    HStack(spacing: Theme.spaceS) {
                        Label(folder.title, systemImage: folder.symbol).lineLimit(1)
                        Spacer(minLength: Theme.spaceS)
                        Text(folder.count, format: .number).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(folder.id)
                    .help(folder.title)
                    .accessibilityLabel("\(folder.title), \(folder.count) videos")
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("\(section.rawValue) output folders")
        }
        .onChange(of: folders.map(\.id), initial: true) { revealSelectedFolder() }
    }

    /// A remembered folder from another group (e.g. a date folder chosen
    /// last time) switches the combo to that group so the row is visible.
    private func revealSelectedFolder() {
        guard let selection, let folder = folders.first(where: { $0.id == selection }),
              folder.section != section else { return }
        sectionRaw = folder.section.rawValue
    }
}
