import SwiftUI

struct OutputFolderList: View {
    let folders: [OutputFolder]
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(OutputFolder.Section.allCases, id: \.self) { section in
                Section(section.rawValue) {
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
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Output folders")
    }
}
