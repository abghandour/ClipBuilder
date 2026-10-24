import SwiftUI

/// Shared controls keep Text, Highlight and Emphasis at feature parity: every
/// word state has its own font, size, weight, style, colour, outline, letter
/// spacing, shadow and word background. Highlight and Emphasis inherit the
/// Text value until changed; Text itself writes the style's own fields so
/// older readers (presets, overlays, the Builder) keep working.
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

    /// Typography shared with the whole-caption fields: Text edits the
    /// style's field, the other states store their own override.
    private func typography<Value>(_ decorKey: WritableKeyPath<CaptionWordDecor, Value?>,
                                   _ styleKey: WritableKeyPath<CaptionStyle, Value?>,
                                   default fallback: Value) -> Binding<Value> {
        Binding(get: { decor[keyPath: decorKey] ?? fallback }, set: { value in
            if state == .text { style[keyPath: styleKey] = value } else { update { $0[keyPath: decorKey] = value } }
        })
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

    /// The word colour of this state: Text colour, Highlight colour or Emphasis colour.
    private var color: Binding<String> {
        switch state {
        case .text: $style.color
        case .highlight: Binding(get: { style.resolvedHighlightColor }, set: { style.highlightColor = $0 })
        case .emphasis: Binding(get: { style.resolvedEmphasisColor }, set: { style.emphasisColor = $0 })
        }
    }

    private var colorHelp: String {
        switch state {
        case .text: "Colour for regular caption text."
        case .highlight: "Colour for the spoken word or its box, when Spoken word is Colour or Box."
        case .emphasis: "Keyword colour when Emphasis includes Colour; follows Highlight colour until changed."
        }
    }

    private var fontFamily: Binding<String?> {
        switch state {
        case .text:
            Binding(get: {
                switch style.font {
                case "sans", "": nil
                case "serif": "Times New Roman"
                case "mono": "Menlo"
                default: style.font
                }
            }, set: { style.font = $0 ?? "sans" })
        case .highlight: stateFont(\.highlightFont)
        case .emphasis: stateFont(\.emphasisFont)
        }
    }

    /// Per-state font: nil inherits the text font; the picker's empty pick clears it.
    private func stateFont(_ key: WritableKeyPath<CaptionStyle, String?>) -> Binding<String?> {
        Binding(get: { style[keyPath: key]?.isEmpty == false ? style[keyPath: key] : nil },
                set: { style[keyPath: key] = $0?.isEmpty == false ? $0 : nil })
    }

    /// "Same as text" for an inherited value, or a button that clears the override.
    @ViewBuilder private func inheritance<Value>(_ key: WritableKeyPath<CaptionWordDecor, Value?>) -> some View {
        if state != .text {
            if stored[keyPath: key] == nil {
                Text("Same as text").foregroundStyle(.secondary).lineLimit(1).fixedSize()
            } else {
                Button("Same as text") { update { $0[keyPath: key] = nil } }.lineLimit(1).fixedSize()
            }
        }
    }

    var body: some View {
        FontFamilyPicker(family: fontFamily, label: "Font", defaultLabel: state == .text ? "Default" : "Same as text")
            .help(state == .text ? "Font for regular caption text and any states that inherit it."
                  : "Font for this word state; Same as text follows the Text font.")
        LabeledContent {
            HStack(spacing: 8) {
                PointSizeField(value: setting(\.size, default: style.resolvedSize(for: .text)), range: 24...120)
                inheritance(\.size)
            }
        } label: {
            Text("Size").lineLimit(1).fixedSize()
        }
        .help(state == .text ? "Font size at 1080 pixels wide."
              : "Font size at 1080 pixels wide; follows the Text size until changed. Scale modes add 12 percent.")
        LabeledContent {
            HStack(spacing: 8) {
                Picker("Weight", selection: typography(\.weight, \.weight, default: "regular")) {
                    Text("Regular").tag("regular")
                    Text("Bold").tag("bold")
                    Text("Black").tag("black")
                }
                .labelsHidden()
                inheritance(\.weight)
            }
        } label: {
            Text("Weight").lineLimit(1).fixedSize()
        }
        .help("Font weight for this word state.")
        LabeledContent {
            TextStyleBar(italic: setting(\.italic, default: false),
                         underline: setting(\.underline, default: false),
                         strikethrough: setting(\.strikethrough, default: false))
        } label: {
            Text("Style").lineLimit(1).fixedSize()
        }
        .help("Italic uses the family's italic face or slants the font; underline and strikethrough draw in the text colour.")
        ColorPicker(selection: overlayColorBinding(color), supportsOpacity: false) {
            Text("Colour").lineLimit(1).fixedSize()
        }
        .help(colorHelp)
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
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: typography(\.strokeWidth, \.strokeWidth, default: 1), in: 0...6, step: 0.5)
                inheritance(\.strokeWidth)
            }
        } label: {
            Text("Outline: \(decor.resolvedStrokeWidth, specifier: "%.1f") pt").lineLimit(1).fixedSize()
        }
        .help("Black outline width at 1080 pixels wide, when the page Background is off.")
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: typography(\.letterSpacing, \.letterSpacing, default: 0), in: -2...6, step: 0.5)
                inheritance(\.letterSpacing)
            }
        } label: {
            Text("Letter spacing: \(decor.resolvedLetterSpacing, specifier: "%.1f") pt").lineLimit(1).fixedSize()
        }
        .help("Space between letters at 1080 pixels wide.")
        LabeledContent {
            HStack(spacing: 8) {
                Toggle("Shadow", isOn: typography(\.shadow, \.shadow, default: false))
                    .labelsHidden().toggleStyle(.switch)
                inheritance(\.shadow)
            }
        } label: {
            Text("Shadow").lineLimit(1).fixedSize()
        }
        .help("Add a soft shadow behind the words in this state.")
    }
}
