import SwiftUI

struct CaptionStyleEditor: View {
    @Binding var name: String
    @Binding var style: CaptionStyle
    let isDefault: Bool

    /// The shared asset/system font picker uses nil for the default sans face.
    private var fontFamily: Binding<String?> {
        Binding(get: {
            switch style.font {
            case "sans", "": nil
            case "serif": "Times New Roman"
            case "mono": "Menlo"
            default: style.font
            }
        }, set: { style.font = $0 ?? "sans" })
    }

    /// Per-state font: nil inherits the text font; the picker's empty pick clears it.
    private func stateFont(_ key: WritableKeyPath<CaptionStyle, String?>) -> Binding<String?> {
        Binding(get: { style[keyPath: key]?.isEmpty == false ? style[keyPath: key] : nil },
                set: { style[keyPath: key] = $0?.isEmpty == false ? $0 : nil })
    }

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
            }
            Section {
                FormGroupHeader("Text")
                FontFamilyPicker(family: fontFamily)
                    .help("Font for regular caption text and any states that inherit it.")
                CaptionWordDecorControls(style: $style, state: .text)
                Picker("Weight", selection: setting(\.weight, default: "regular")) {
                    Text("Regular").tag("regular")
                    Text("Bold").tag("bold")
                    Text("Black").tag("black")
                }.help("Font weight used for captions.")
                Toggle("Uppercase", isOn: setting(\.uppercase, default: false))
                    .help("Display captions in uppercase without changing the transcript.")
                Picker("Words per page", selection: $style.wordsPerPage) {
                    Text("Fit two rows").tag(nil as Int?)
                    ForEach(1...8, id: \.self) { Text(String($0)).tag(Optional($0)) }
                }.help("Limit each page to a word count, or fit up to two rows.")
                Picker("Position", selection: $style.position) {
                    Text("Top").tag("top")
                    Text("Middle").tag("middle")
                    Text("Bottom").tag("bottom")
                }.help("Default caption position; individual clips can override it.")
                Picker("Alignment", selection: alignment) {
                    Text("Leading").lineLimit(1).fixedSize().tag("leading")
                    Text("Center").lineLimit(1).fixedSize().tag("center")
                    Text("Trailing").lineLimit(1).fixedSize().tag("trailing")
                }
                .pickerStyle(.segmented)
                ColorPicker("Text colour", selection: overlayColorBinding($style.color), supportsOpacity: false)
                    .help("Colour for regular caption text.")
                Toggle("Background", isOn: $style.bgOn)
                    .help("Fill a background behind the whole caption page.")
                if style.bgOn {
                    ColorPicker("Background colour", selection: overlayColorBinding($style.bgColor), supportsOpacity: false)
                        .help("Colour of the caption page background.")
                    Slider(value: setting(\.bgRadius, default: style.resolvedPageRadius), in: 0...60, step: 1) {
                        Text("Corner radius: \(Int(style.resolvedPageRadius)) pt").lineLimit(1).fixedSize()
                    }
                    .help("Round the page background corners at 1080 pixels wide. Zero makes square corners.")
                    .formDependent()
                }
                Slider(value: setting(\.strokeWidth, default: 1), in: 0...6, step: 0.5) {
                    Text("Outline: \(style.resolvedStrokeWidth, specifier: "%.1f") pt").lineLimit(1).fixedSize()
                }.help("Black outline width at 1080 pixels wide, when Background is off.")
                Slider(value: setting(\.letterSpacing, default: 0), in: -2...6, step: 0.5) {
                    Text("Letter spacing: \(style.resolvedLetterSpacing, specifier: "%.1f") pt").lineLimit(1).fixedSize()
                }.help("Space between letters at 1080 pixels wide.")
                Toggle("Shadow", isOn: setting(\.shadow, default: false))
                    .help("Add a soft shadow behind the text.")
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
                    FormCaption("Colours follow speaker identity. A line spanning speakers uses the first speaker.")
                }
                FormCaption(isDefault
                    ? "Used whenever a run selects Profile default. Changes save automatically."
                    : "Available in this profile’s Express and full Wizard. Changes save automatically.")
            }
            Section {
                FormGroupHeader("Highlight")
                Picker("Spoken word", selection: setting(\.highlight, default: "none")) {
                    Text("None").tag("none")
                    Text("Colour").tag("color")
                    Text("Box").tag("box")
                    Text("Scale").tag("scale")
                }.help("Highlight each word while it is spoken. Translations use evenly timed words.")
                Picker(selection: setting(\.reveal, default: style.resolvedReveal)) {
                    Text("All at once").lineLimit(1).fixedSize().tag("none")
                    Text("As spoken").lineLimit(1).fixedSize().tag("word")
                } label: {
                    Text("Words appear").lineLimit(1).fixedSize()
                }
                .help("Show each word of a page as it is spoken. Makes no difference with one word per page.")
                if style.resolvedReveal == "word" {
                    Toggle(isOn: setting(\.revealMotion, default: false)) {
                        Text("Animate each word").lineLimit(1).fixedSize()
                    }
                    .disabled(style.resolvedAnimation == "none")
                    .help("Each new word uses the Motion entrance; off animates only the page.")
                    .formDependent()
                    if style.resolvedAnimation == "none" {
                        FormCaption("Choose a Motion entrance first.")
                    }
                }
                ColorPicker("Highlight colour", selection: overlayColorBinding(setting(\.highlightColor, default: "#ffd60a")), supportsOpacity: false)
                    .help("Colour for the spoken word or its box.")
                FontFamilyPicker(family: stateFont(\.highlightFont), label: "Highlight font", defaultLabel: "Same as text")
                    .help("Font for the spoken word; Same as text follows the Text font.")
                CaptionWordDecorControls(style: $style, state: .highlight)
            }
            Section {
                FormGroupHeader("Emphasis")
                Picker("Emphasis", selection: setting(\.emphasis, default: "none")) {
                    Text("None").tag("none")
                    Text("Colour").tag("color")
                    Text("Scale").tag("scale")
                    Text("Colour and scale").tag("both")
                }.help("Emphasise up to two keywords per page, chosen on this Mac.")
                ColorPicker("Emphasis colour", selection: overlayColorBinding(setting(\.emphasisColor, default: style.resolvedHighlightColor)), supportsOpacity: false)
                    .help("Keyword colour; follows Highlight colour until changed.")
                FontFamilyPicker(family: stateFont(\.emphasisFont), label: "Emphasis font", defaultLabel: "Same as text")
                    .help("Font for emphasised keywords; Same as text follows the Text font.")
                CaptionWordDecorControls(style: $style, state: .emphasis)
                Toggle("Emoji", isOn: setting(\.emoji, default: false))
                    .help("Append a matching emoji when the page contains a supported keyword.")
            }
            Section {
                FormGroupHeader("Motion")
                Picker("Page entrance", selection: setting(\.animation, default: "none")) {
                    Text("None").tag("none")
                    Text("Pop").tag("pop")
                    Text("Slide up").tag("slide-up")
                    Text("Fade").tag("fade")
                }.help("Animate each new caption page.")
            }
        }
        .formStyle(.grouped)
    }
}
