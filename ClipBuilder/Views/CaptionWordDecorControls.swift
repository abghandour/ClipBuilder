import SwiftUI

struct CaptionWordDecorControls: View {
    @Binding var style: CaptionStyle
    let state: CaptionStyle.WordState
    var sharedStyles: [NamedTextStyle] = []

    private var stored: CaptionWordDecor {
        switch state {
        case .text: style.text ?? CaptionWordDecor()
        case .highlight: style.highlightDecor ?? CaptionWordDecor()
        case .emphasis: style.emphasisDecor ?? CaptionWordDecor()
        case .emphasis2: style.emphasis2Decor ?? CaptionWordDecor()
        }
    }

    private var decoration: Binding<TextDecor?> {
        Binding(get: { stored.decor }, set: { value in
            var word = stored
            word.decor = value
            switch state {
            case .text: style.text = word
            case .highlight: style.highlightDecor = word
            case .emphasis: style.emphasisDecor = word
            case .emphasis2: style.emphasis2Decor = word
            }
        })
    }

    private var family: Binding<String?> {
        switch state {
        case .text: Binding(get: { style.fontOverride }, set: { style.fontOverride = $0 })
        case .highlight: $style.highlightFont
        case .emphasis: $style.emphasisFont
        case .emphasis2: $style.emphasis2Font
        }
    }

    private var inherited: TextDecor {
        var copy = style.applyingSharedStyle(sharedStyles)
        switch state {
        case .text: copy.text?.decor = nil
        case .highlight: copy.highlightDecor?.decor = nil
        case .emphasis: copy.emphasisDecor?.decor = nil
        case .emphasis2: copy.emphasis2Decor?.decor = nil
        }
        return copy.resolvedTextDecor(for: state)
    }

    var lookState: TextLookSurface.State {
        TextLookSurface.State(id: state == .text ? "Text" : state == .highlight ? "Highlight" : state == .emphasis2 ? "Emphasis 2" : "Emphasis",
            decor: decoration, fontFamily: family, inherited: inherited,
            parent: state == .text ? "Inherited" : "Text", maxWidth: 0.86,
            sharedStyleID: state == .text ? $style.sharedStyleID : nil,
            source: state == .text ? "caption" : "caption state")
    }

    private func setting<Value>(_ key: WritableKeyPath<CaptionWordDecor, Value?>, default fallback: Value) -> Binding<Value> {
        Binding(get: { stored[keyPath: key] ?? fallback }, set: { value in
            var word = stored
            word[keyPath: key] = value
            switch state {
            case .text: style.text = word
            case .highlight: style.highlightDecor = word
            case .emphasis: style.emphasisDecor = word
            case .emphasis2: style.emphasis2Decor = word
            }
        })
    }

    @ViewBuilder var layoutOptions: some View {
        if state == .emphasis || state == .emphasis2 {
            TextLookRow("Emphasis line") {
                Toggle("Fit on one line", isOn: Binding(
                    get: { stored.fitLineMinimumScale != nil },
                    set: { enabled in
                        var word = stored
                        word.fitLineMinimumScale = enabled ? 0.6 : nil
                        if state == .emphasis2 { style.emphasis2Decor = word }
                        else { style.emphasisDecor = word }
                    }))
                    .lineLimit(1).fixedSize()
            }.help("Keep emphasis and surrounding words on one baseline, scaling their sizes and spacing together. Longer pages wrap at the minimum scale.")
            if stored.fitLineMinimumScale != nil {
                TextLookRow("Minimum scale") {
                    Slider(value: setting(\.fitLineMinimumScale, default: 0.6), in: 0.25...1, step: 0.01)
                    Text(stored.resolvedFitLineMinimumScale ?? 0.6, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().fixedSize()
                }
            }
            TextLookRow("Between words") {
                Toggle("Keep emphasis highlighted", isOn: setting(\.highlightHold, default: style.resolvedHighlightHold))
                    .lineLimit(1).fixedSize()
            }.help("Keep the spoken colour after an emphasis word ends. Off restores its emphasis colour at the end of its word timing.")
            TextLookRow("While spoken") {
                Toggle("Take the spoken colour", isOn: setting(\.takesHighlightColor, default: true))
                    .lineLimit(1).fixedSize()
            }.help("Off keeps this emphasis word in its own colour while it is being spoken.")
        }
    }

    var body: some View {
        TextLookInspector(decor: decoration, fontFamily: family, inherited: inherited,
                          defaultLabel: state == .text ? "Inherited" : "Same as text", defaultMaxWidth: 0.86,
                          sharedStyleID: state == .text ? $style.sharedStyleID : nil,
                          sourceLabel: state == .text ? "caption" : "caption \(state == .highlight ? "highlight" : "emphasis")")
        layoutOptions
    }
}
