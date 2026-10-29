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
            }
        })
    }

    private var family: Binding<String?> {
        switch state {
        case .text: Binding(get: { style.fontOverride }, set: { style.fontOverride = $0 })
        case .highlight: $style.highlightFont
        case .emphasis: $style.emphasisFont
        }
    }

    private var inherited: TextDecor {
        var copy = style.applyingSharedStyle(sharedStyles)
        switch state {
        case .text: copy.text?.decor = nil
        case .highlight: copy.highlightDecor?.decor = nil
        case .emphasis: copy.emphasisDecor?.decor = nil
        }
        return copy.resolvedTextDecor(for: state)
    }

    var lookState: TextLookSurface.State {
        TextLookSurface.State(id: state == .text ? "Text" : state == .highlight ? "Highlight" : "Emphasis",
            decor: decoration, fontFamily: family, inherited: inherited,
            parent: state == .text ? "Inherited" : "Text", maxWidth: 0.86,
            sharedStyleID: state == .text ? $style.sharedStyleID : nil,
            source: state == .text ? "caption" : "caption state")
    }

    var body: some View {
        TextLookInspector(decor: decoration, fontFamily: family, inherited: inherited,
                          defaultLabel: state == .text ? "Inherited" : "Same as text", defaultMaxWidth: 0.86,
                          sharedStyleID: state == .text ? $style.sharedStyleID : nil,
                          sourceLabel: state == .text ? "caption" : "caption \(state == .highlight ? "highlight" : "emphasis")")
    }
}
