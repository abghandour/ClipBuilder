import CoreGraphics
import Foundation
import SwiftUI

struct TelestratorToolbar: View {
    let editor: TelestratorEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 8) {
                ForEach(TelestratorEditor.Tool.allCases, id: \.self) { tool in
                    Button { editor.tool = tool } label: {
                        Text(tool.label).lineLimit(1).fixedSize()
                    }
                    .tint(editor.tool == tool ? .accentColor : .secondary)
                    .accessibilityValue(editor.tool == tool ? "Selected" : "")
                    .disabled(tool != .select && editor.atLimit)
                    .help(tool != .select && editor.atLimit ? "A drawing can contain at most 12 figures. Delete one to draw another." : tool.label)
                }

                ForEach(Telestration.Figure.Color.allCases, id: \.self) { color in
                    Button { editor.setColor(color) } label: {
                        let rgb = color.components
                        Circle()
                            .fill(Color(red: Double(rgb.red), green: Double(rgb.green), blue: Double(rgb.blue)))
                            .overlay { Circle().strokeBorder(.black.opacity(0.4)) }
                            .overlay {
                                if editor.color == color {
                                    Image(systemName: "checkmark").foregroundStyle(.black)
                                }
                            }
                            .frame(width: 22, height: 22)
                    }
                    .accessibilityLabel(color.rawValue.capitalized)
                    .accessibilityValue(editor.color == color ? "Selected" : "")
                    .help("\(color.rawValue.capitalized) stroke")
                }

                ForEach(Telestration.Figure.widths.enumerated(), id: \.offset) { index, width in
                    Button { editor.setWidth(width) } label: {
                        Text(["Thin", "Medium", "Thick"][index]).lineLimit(1).fixedSize()
                    }
                    .tint(editor.width == width ? .accentColor : .secondary)
                    .accessibilityValue(editor.width == width ? "Selected" : "")
                }

                Button(action: editor.undo) {
                    Label("Undo", systemImage: "arrow.uturn.backward").lineLimit(1).fixedSize()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(editor.undoDrawing == nil)
                Button(action: editor.deleteSelected) {
                    Label("Delete", systemImage: "trash").lineLimit(1).fixedSize()
                }
                .disabled(editor.selected == nil)
                Button(action: editor.clear) { Text("Clear").lineLimit(1).fixedSize() }
                    .disabled(editor.drawing.figures.isEmpty)
            }
            .buttonStyle(.bordered)
            .disabled(editor.isDragging || editor.playStarted != nil)
            FlowLayout(spacing: 8) {
                Toggle(isOn: Binding(get: { editor.head }, set: { editor.setHead($0) })) {
                    Text("Head").lineLimit(1).fixedSize()
                }
                .toggleStyle(.button)
                .disabled(!editor.canSetHead)
                .help("Add an arrow head to a free line")
                ForEach(Telestration.Figure.Style.allCases, id: \.self) { style in
                    Button { editor.setStyle(style) } label: {
                        Text(style.rawValue.capitalized).lineLimit(1).fixedSize()
                    }
                    .tint(editor.style == style ? .accentColor : .secondary)
                    .accessibilityValue(editor.style == style ? "Selected" : "")
                }
                if editor.showsSymbols {
                    ForEach(Telestration.Figure.symbols, id: \.self) { symbol in
                        Button { editor.setSymbol(symbol) } label: {
                            Image(systemName: symbol).frame(width: 22, height: 22)
                        }
                        .tint(editor.symbol == symbol ? .accentColor : .secondary)
                        .accessibilityLabel(symbolLabel(symbol))
                        .accessibilityValue(editor.symbol == symbol ? "Selected" : "")
                        .help(symbolLabel(symbol))
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(editor.isDragging || editor.playStarted != nil)
            if editor.atLimit {
                Text("12-figure limit reached. Delete a figure to draw another.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
    }

    private func symbolLabel(_ symbol: String) -> String {
        switch symbol {
        case "brain": "Brain"
        case "eye": "Eye"
        case "exclamationmark.triangle": "Warning"
        case "bolt.fill": "Lightning"
        case "target": "Target"
        case "shield": "Shield"
        case "figure.boxing": "Boxer"
        default: "Repeat"
        }
    }
}
