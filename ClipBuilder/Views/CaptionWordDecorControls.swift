import SwiftUI

/// Shared controls keep Text, Highlight and Emphasis at feature parity.
struct CaptionWordDecorControls: View {
    @Binding var style: CaptionStyle
    let state: CaptionStyle.WordState

    private var decor: CaptionWordDecor { style.resolvedDecor(for: state) }
    private var stored: CaptionWordDecor {
        switch state {
        case .text: style.text ?? CaptionWordDecor()
        case .highlight: style.highlightDecor ?? CaptionWordDecor()
        case .emphasis: style.emphasisDecor ?? CaptionWordDecor()
        }
    }

    private func update(_ change: (inout CaptionWordDecor) -> Void) {
        var value = stored
        change(&value)
        switch state {
        case .text: style.text = value
        case .highlight: style.highlightDecor = value
        case .emphasis: style.emphasisDecor = value
        }
    }

    private func setting<Value>(_ key: WritableKeyPath<CaptionWordDecor, Value?>, default fallback: Value) -> Binding<Value> {
        Binding(get: { decor[keyPath: key] ?? fallback }, set: { value in update { $0[keyPath: key] = value } })
    }

    private var background: Binding<Bool> {
        Binding(get: { decor.resolvedBackground }, set: { enabled in
            update { $0.bgOn = enabled }
            // Turning off the background also leaves Box mode.
            if !enabled && state == .highlight && style.resolvedHighlight == "box" { style.highlight = "color" }
        })
    }

    private var backgroundColor: String {
        if let color = stored.bgColor { return color }
        switch state {
        case .text: return style.color
        case .highlight: return style.resolvedHighlightColor
        case .emphasis: return style.resolvedEmphasisColor
        }
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                PointSizeField(value: setting(\.size, default: style.resolvedSize(for: .text)), range: 24...120)
                if state != .text {
                    if stored.size == nil {
                        Text("Same as text").foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    } else {
                        Button("Same as text") { update { $0.size = nil } }.lineLimit(1).fixedSize()
                    }
                }
            }
        } label: {
            Text("Size").lineLimit(1).fixedSize()
        }
        .help(state == .text ? "Font size at 1080 pixels wide."
              : "Font size at 1080 pixels wide; follows the Text size until changed. Scale modes add 12 percent.")
        LabeledContent {
            TextStyleBar(italic: setting(\.italic, default: false),
                         underline: setting(\.underline, default: false),
                         strikethrough: setting(\.strikethrough, default: false))
        } label: {
            Text("Style").lineLimit(1).fixedSize()
        }
        .help("Italic uses the family's italic face or slants the font; underline and strikethrough draw in the text colour.")
        Toggle(isOn: background) { Text("Word background").lineLimit(1).fixedSize() }
            .help("Fill a padded background behind each word in this state.")
        if decor.resolvedBackground {
            ColorPicker(selection: overlayColorBinding(setting(\.bgColor, default: backgroundColor)), supportsOpacity: false) {
                Text("Word background colour").lineLimit(1).fixedSize()
            }
            .help("Choose the word background colour. Until changed, it follows the text colour at 25 percent opacity; Box uses a solid highlight colour.")
            .formDependent()
            Slider(value: setting(\.bgRadius, default: 6), in: 0...40, step: 1) {
                Text("Corner radius: \(Int(decor.resolvedRadius)) pt").lineLimit(1).fixedSize()
            }
            .help("Round the word background corners at 1080 pixels wide. Zero makes square corners.")
            .formDependent()
        }
    }
}
