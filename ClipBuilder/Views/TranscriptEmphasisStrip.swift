import SwiftUI

/// Explicit word buttons make selection available without relying on a text menu.
struct TranscriptEmphasisStrip: View {
    let words: [TranscriptWord]
    let onMark: (Set<Int>, String) -> Void
    @State private var selected: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(words.indices, id: \.self) { index in
                        Button {
                            if selected.contains(index) { selected.remove(index) }
                            else { selected.insert(index) }
                        } label: {
                            Text(words[index].word + suffix(words[index].emphasis))
                                .fontWeight(selected.contains(index) ? .bold : .regular)
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .background(selected.contains(index) ? Color.accentColor.opacity(0.2) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(words[index].word), \(label(words[index].emphasis))")
                        .accessibilityAddTraits(selected.contains(index) ? .isSelected : [])
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { choices; legend }
                VStack(alignment: .leading, spacing: 6) { choices; legend }
            }
        }
        .font(.caption).lineLimit(1).fixedSize(horizontal: false, vertical: true)
        .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .onChange(of: words.map(\.word)) { selected = [] }
    }

    private var choices: some View {
        HStack(spacing: 6) {
            Text(selected.isEmpty ? "Select words" : "\(selected.count) selected").fixedSize()
            Menu("Set emphasis") {
                Button("Automatic") { mark("automatic") }
                Button("Off") { mark("none") }
                Button("Emphasis") { mark("primary") }
                Button("Emphasis 2") { mark("alternate") }
            }.disabled(selected.isEmpty).fixedSize()
        }
    }

    /// Each mark ends its selection, so the next click starts a new one.
    private func mark(_ value: String) {
        onMark(selected, value)
        selected = []
    }

    private var legend: some View {
        Text("1: Emphasis · 2: Emphasis 2 · Off: no emphasis").foregroundStyle(.secondary).fixedSize()
    }

    private func suffix(_ mark: String?) -> String {
        switch mark {
        case "primary": " ¹"
        case "alternate": " ²"
        case "none": " ⊘"
        default: ""
        }
    }

    private func label(_ mark: String?) -> String {
        switch mark {
        case "primary": "Emphasis"
        case "alternate": "Emphasis 2"
        case "none": "Off"
        default: "Automatic"
        }
    }
}
