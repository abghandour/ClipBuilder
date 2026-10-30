import SwiftUI

struct CaptionStyleEditor: View {
    @Binding var name: String
    @Binding var style: CaptionStyle
    let isDefault: Bool
    @Binding var selectedState: String
    @Environment(AppStore.self) private var store

    private var surface: TextLookSurface {
        let shared = store.activeProfile.textStyles ?? []
        let words: [CaptionStyle.WordState] = [.text, .highlight, .emphasis]
        let states = words.map { CaptionWordDecorControls(style: $style, state: $0, sharedStyles: shared).lookState }
        var parent = style
        parent.decor = nil
        parent = parent.applyingSharedStyle(shared)
        return TextLookSurface(
            states: states + [
                .init(
                    id: "Page", decor: $style.decor,
                    fontFamily: .constant(nil), inherited: (parent.decor ?? TextDecor()).resolved(over: parent.legacyDecor), boxOnly: true,
                    source: "caption page")
            ],
            selection: $selectedState, sample: .captions)
    }

    private func setting<Value>(
        _ key: WritableKeyPath<CaptionStyle, Value?>,
        default fallback: Value
    ) -> Binding<Value> {
        Binding(get: { style[keyPath: key] ?? fallback }, set: { style[keyPath: key] = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spaceM) {
                TextField("Name", text: $name).disabled(isDefault)
                    .help(WizardFieldHelp.textDecor["name"]!.tooltip)
                TextLookInspector(surface: surface) {
                    stateOptions
                }
            }.padding(12)
        }
    }

    @ViewBuilder private var stateOptions: some View {
        switch selectedState {
        case "Page": pageOptions
        case "Highlight":
            TextLookRow("Spoken word") {
                Picker("Spoken word", selection: setting(\.highlight, default: "none")) {
                    Text("None").tag("none")
                    Text("Colour").tag("color")
                    Text("Box").tag("box")
                    Text("Scale").tag("scale")
                }
            }.help("Highlight each word while it is spoken. Translations use evenly timed words.")
        case "Emphasis":
            TextLookRow("Emphasis") {
                Picker("Emphasis", selection: setting(\.emphasis, default: "none")) {
                    Text("None").tag("none")
                    Text("Colour").tag("color")
                    Text("Scale").tag("scale")
                    Text("Colour and scale").tag("both")
                    Text("Font only").tag("font")
                }
            }.help("Emphasise up to two keywords per page, chosen on this Mac")
        default: EmptyView()
        }
    }

    private var pageOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextLookRow("Words per page") {
                Picker("Words per page", selection: $style.wordsPerPage) {
                    Text("Fit two rows").tag(nil as Int?)
                    ForEach(1...8, id: \.self) { Text(String($0)).tag(Optional($0)) }
                }
            }.help("Limit each page to a word count, or fit up to two rows")
            TextLookRow("Position") {
                Picker("Position", selection: $style.position) {
                    Text("Top").tag("top")
                    Text("Middle").tag("middle")
                    Text("Bottom").tag("bottom")
                }
            }.help("Default caption position; individual clips can override it")
            TextLookRow("Words appear") {
                Picker("Words appear", selection: setting(\.reveal, default: style.resolvedReveal)) {
                    Text("All at once").tag("none")
                    Text("As spoken").tag("word")
                }
            }.help("Show each word of a page as it is spoken. Makes no difference with one word per page.")
            TextLookRow("Page entrance") {
                Picker("Page entrance", selection: setting(\.animation, default: "none")) {
                    Text("None").tag("none")
                    Text("Pop").tag("pop")
                    Text("Slide up").tag("slide-up")
                    Text("Fade").tag("fade")
                }
            }.help("Animate each new caption page")
            if style.resolvedReveal == "word" {
                TextLookRow("Each word") {
                    Toggle("Animate each word", isOn: setting(\.revealMotion, default: false))
                        .disabled(style.resolvedAnimation == "none")
                }
                .help("Each new word uses the Page entrance; off animates only the page")
                .formDependent()
                if style.resolvedAnimation == "none" {
                    FormCaption("Choose a Page entrance first.")
                }
            }
            TextLookRow("Emoji") { Toggle("Emoji", isOn: setting(\.emoji, default: false)) }
                .help("Append a matching emoji when the page contains a supported keyword")
            TextLookRow("Speaker colours") { Toggle("Speaker colours", isOn: setting(\.speakerColors, default: false)) }
                .help("Use a consistent text colour for each speaker when speaker turns are available")
            if style.resolvedSpeakerColors {
                TextLookRow("Palette") {
                    HStack(spacing: 4) {
                        ForEach(Array(CaptionSpeakerColors.palette.enumerated()), id: \.offset) { index, hex in
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.black)
                                .frame(width: 24, height: 24)
                                .background(Color(hex: hex) ?? .white, in: .circle)
                                .accessibilityLabel("Speaker colour \(index + 1), \(hex)")
                        }
                    }
                }
                .formDependent()
                FormCaption("Colours follow speaker identity. A line spanning speakers uses the first speaker.")
            }
        }.lineLimit(1).fixedSize(horizontal: false, vertical: true)
    }
}
