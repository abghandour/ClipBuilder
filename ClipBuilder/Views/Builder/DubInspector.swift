import SwiftUI

struct DubInspector: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        InspectorSection("Dub") {
            if let dub = store.builder.document.dub {
                let lines = store.builder.document.dubLines ?? []
                Text(DubLanguageChoices.name(dub.language)).font(.callout)
                Text("\(lines.count) lines · \(lines.filter(\.tight).count) tight")
                    .font(.caption).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { controls }
                    VStack(alignment: .leading) { controls }
                }
            } else {
                ContentUnavailableView {
                    Label("No Dub", systemImage: "waveform")
                } description: {
                    Text("Use Dub… in the toolbar to add one.")
                }
            }
        }
        .padding()
    }

    @ViewBuilder private var controls: some View {
        Button("Review lines…") { store.reviewTimelineDub() }
            .lineLimit(1).fixedSize()
        Button("Remove dub", role: .destructive) { store.builder.setDub(settings: nil, lines: nil) }
            .lineLimit(1).fixedSize()
    }
}
