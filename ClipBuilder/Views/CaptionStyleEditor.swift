import SwiftUI

struct CaptionStyleEditor: View {
    @Binding var name: String
    @Binding var style: CaptionStyle
    let isDefault: Bool

    private var alignment: Binding<String> {
        Binding(get: { style.alignment ?? "center" }, set: { style.alignment = $0 == "center" ? nil : $0 })
    }

    private func setting<Value>(_ key: WritableKeyPath<CaptionStyle, Value?>,
                                default fallback: Value) -> Binding<Value> {
        Binding(get: { style[keyPath: key] ?? fallback }, set: { style[keyPath: key] = $0 })
    }

    var body: some View {
        Form {
            Section {
                FormGroupHeader(isDefault ? "Profile default" : "Caption style")
                TextField("Name", text: $name).disabled(isDefault)
                SharedTextStylePicker(selection: $style.sharedStyleID)
            }
            Section {
                FormGroupHeader("Captions")
                Picker("Words per page", selection: $style.wordsPerPage) {
                    Text("Fit two rows").tag(nil as Int?)
                    ForEach(1...8, id: \.self) { Text(String($0)).tag(Optional($0)) }
                }.help("Limit each page to a word count, or fit up to two rows.")
                Picker("Position", selection: $style.position) {
                    Text("Top").tag("top")
                    Text("Middle").tag("middle")
                    Text("Bottom").tag("bottom")
                }.help("Default caption position; individual clips can override it.")
                TextDecorControls(decor: $style.decor, fontFamily: .constant(nil), inherited: style.legacyDecor, boxOnly: true,
                                  sourceLabel: "caption page")
                Picker(selection: setting(\.reveal, default: style.resolvedReveal)) {
                    Text("All at once").lineLimit(1).fixedSize().tag("none")
                    Text("As spoken").lineLimit(1).fixedSize().tag("word")
                } label: {
                    Text("Words appear").lineLimit(1).fixedSize()
                }
                .help("Show each word of a page as it is spoken. Makes no difference with one word per page.")
                Picker("Page entrance", selection: setting(\.animation, default: "none")) {
                    Text("None").tag("none")
                    Text("Pop").tag("pop")
                    Text("Slide up").tag("slide-up")
                    Text("Fade").tag("fade")
                }.help("Animate each new caption page.")
                if style.resolvedReveal == "word" {
                    Toggle(isOn: setting(\.revealMotion, default: false)) {
                        Text("Animate each word").lineLimit(1).fixedSize()
                    }
                    .disabled(style.resolvedAnimation == "none")
                    .help("Each new word uses the Page entrance; off animates only the page.")
                    .formDependent()
                    if style.resolvedAnimation == "none" {
                        FormCaption("Choose a Page entrance first.")
                    }
                }
                Toggle("Emoji", isOn: setting(\.emoji, default: false))
                    .help("Append a matching emoji when the page contains a supported keyword.")
                Toggle("Speaker colours", isOn: setting(\.speakerColors, default: false))
                    .help("Use a consistent text colour for each speaker when speaker turns are available.")
                if style.resolvedSpeakerColors {
                    HStack {
                        Text("Speaker palette").lineLimit(1).fixedSize()
                        ForEach(Array(CaptionSpeakerColors.palette.enumerated()), id: \.offset) { index, hex in
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.black)
                                .frame(width: 24, height: 24)
                                .background(Color(hex: hex) ?? .white, in: .circle)
                                .accessibilityLabel("Speaker colour \(index + 1), \(hex)")
                        }
                    }
                    .formDependent()
                    FormCaption("Colours follow speaker identity. A line spanning speakers uses the first speaker.")
                }
                FormCaption(isDefault
                    ? "Used whenever a run selects Profile default. Changes save automatically."
                    : "Available in this profile’s Express and full Wizard. Changes save automatically.")
            }
            Section {
                FormGroupHeader("Text")
                CaptionWordDecorControls(style: $style, state: .text)
                FormCaption("Regular words. Highlight and Emphasis follow these settings until changed.")
            }
            Section {
                FormGroupHeader("Highlight")
                Picker("Spoken word", selection: setting(\.highlight, default: "none")) {
                    Text("None").tag("none")
                    Text("Colour").tag("color")
                    Text("Box").tag("box")
                    Text("Scale").tag("scale")
                }.help("Highlight each word while it is spoken. Translations use evenly timed words.")
                CaptionWordDecorControls(style: $style, state: .highlight)
            }
            Section {
                FormGroupHeader("Emphasis")
                Picker("Emphasis", selection: setting(\.emphasis, default: "none")) {
                    Text("None").tag("none")
                    Text("Colour").tag("color")
                    Text("Scale").tag("scale")
                    Text("Colour and scale").tag("both")
                    Text("Font only").tag("font")
                }.help("Emphasise up to two keywords per page, chosen on this Mac.")
                CaptionWordDecorControls(style: $style, state: .emphasis)
            }
        }
        .formStyle(.grouped)
    }
}
