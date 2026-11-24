import SwiftUI

struct CaptionStyleEditor: View {
    @Binding var name: String
    @Binding var style: CaptionStyle
    let isDefault: Bool
    @Binding var selectedState: String
    @Environment(AppStore.self) private var store

    private var surface: TextLookSurface {
        let shared = store.activeProfile.textStyles ?? []
        let words: [CaptionStyle.WordState] = [.text, .highlight, .emphasis, .emphasis2]
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
            TextLookRow("Between words") {
                Toggle("Keep last word highlighted", isOn: setting(\.highlightHold, default: false))
                    .lineLimit(1).fixedSize()
            }
        case "Emphasis", "Emphasis 2":
            TextLookRow("Emphasis") {
                Picker("Emphasis", selection: setting(selectedState == "Emphasis 2" ? \.emphasis2 : \.emphasis,
                                                       default: selectedState == "Emphasis 2" ? style.resolvedEmphasis : "none")) {
                    Text("None").tag("none")
                    Text("Colour").tag("color")
                    Text("Scale").tag("scale")
                    Text("Colour and scale").tag("both")
                    Text("Font only").tag("font")
                }
            }.help("Untouched pages choose keywords on this Mac. Choose individual words in the transcript editor. Emphasis None disables both looks.")
            CaptionWordDecorControls(style: $style, state: selectedState == "Emphasis 2" ? .emphasis2 : .emphasis).layoutOptions
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
            TextLookRow("Line breaks") {
                Picker("Line breaks", selection: setting(\.lineBreaks, default: "balanced")) {
                    Text("Balanced").tag("balanced")
                    Text("Fill each row").tag("greedy")
                    Text("Sentence rows").tag("sentence")
                    Text("Sentence and comma rows").tag("clause")
                }
            }
            TextLookRow("Line spacing") {
                Toggle("Custom baseline spacing", isOn: Binding(
                    get: { style.lineSpacing != nil },
                    set: { style.lineSpacing = $0 ? 136 : nil }))
            }
            if style.lineSpacing != nil {
                TextLookRow("Baseline pixels") {
                    Slider(value: setting(\.lineSpacing, default: 136), in: 24...300, step: 1)
                    Text("\(Int(style.resolvedLineSpacing ?? 136))").monospacedDigit().fixedSize()
                }.help("Distance between baselines on a 1080-pixel-wide video")
            }
            TextLookRow("Word spacing") {
                Toggle("Custom space width", isOn: Binding(
                    get: { style.wordSpacing != nil },
                    set: { style.wordSpacing = $0 ? 22 : nil }))
            }
            if style.wordSpacing != nil {
                TextLookRow("Space pixels") {
                    Slider(value: setting(\.wordSpacing, default: 22), in: 0...120, step: 1)
                    Text("\(Int(style.resolvedWordSpacing ?? 22))").monospacedDigit().fixedSize()
                }.help("Space between word slots on a 1080-pixel-wide video")
            }
            TextLookRow("Position") {
                Picker("Position", selection: $style.position) {
                    Text("Top").tag("top")
                    Text("Middle").tag("middle")
                    Text("Bottom").tag("bottom")
                    if CustomPosition.isCustom(style.position) {
                        Text("Custom").tag(style.position)
                    }
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
                    Text("Bounce").lineLimit(1).fixedSize().tag("bounce")
                    Text("Slide up").tag("slide-up")
                    Text("Fade").tag("fade")
                    Text("Soft fade (3 frames)").tag("soft-fade")
                }
            }.help("Animate each new caption page")
            if style.resolvedReveal == "word" {
                TextLookRow("Word positions") {
                    Picker("Word positions", selection: setting(\.revealLayout, default: "flow")) {
                        Text("Reflow as spoken").tag("flow")
                        Text("Reserve full page").tag("fixed")
                    }
                }
                TextLookRow("Each word") {
                    Toggle("Animate each word", isOn: setting(\.revealMotion, default: false))
                        .disabled(style.resolvedAnimation == "none")
                }
                .help(style.resolvedFixedReveal
                    ? "Animate each entering word in its reserved slot; off animates only the first word"
                    : "Each new word uses the Page entrance; off animates only the page")
                .formDependent()
                if style.resolvedAnimation == "none" {
                    FormCaption("Choose a Page entrance first.")
                }
                if style.resolvedRevealMotion && style.resolvedAnimation != "none" {
                    TextLookRow("Skip fast entrances") {
                        Slider(value: setting(\.animationMinimumWordDuration, default: 0), in: 0...1, step: 0.05)
                        Text(style.resolvedAnimationMinimumWordDuration, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit().fixedSize()
                    }.help("Words with a shorter on-screen interval appear immediately; seconds")
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
