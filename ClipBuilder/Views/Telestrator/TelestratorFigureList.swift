import SwiftUI

struct TelestratorFigureList: View {
    let editor: TelestratorEditor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Drawing order").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary).textCase(.uppercase).lineLimit(1).fixedSize()
                if editor.drawing.figures.isEmpty {
                    Text("Choose a tool and drag on the picture to draw.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(editor.drawing.figures.indices, id: \.self) { index in
                    let figure = editor.drawing.figures[index]
                    HStack(spacing: 4) {
                        Button { editor.select(index) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: editor.selected == index ? "checkmark.circle.fill" : "circle")
                                Text("\(index + 1). \(figure.kind.label)").lineLimit(1).fixedSize()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Figure \(index + 1), \(figure.color.rawValue) \(figure.kind.label)")
                        .accessibilityValue(editor.selected == index ? "Selected" : "")
                        Button("Move up", systemImage: "chevron.up") { editor.move(index, by: -1) }
                            .labelStyle(.iconOnly).disabled(index == 0)
                            .help("Draw this figure earlier")
                        Button("Move down", systemImage: "chevron.down") { editor.move(index, by: 1) }
                            .labelStyle(.iconOnly).disabled(index == editor.drawing.figures.count - 1)
                            .help("Draw this figure later")
                    }
                    .padding(6)
                    .background(editor.selected == index ? Color.accentColor.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(10)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .disabled(editor.isDragging || editor.isPlaying)
    }
}
