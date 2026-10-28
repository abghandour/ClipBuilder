import SwiftUI

/// Every text surface uses the same rows and sparse override bindings.
struct TextDecorControls: View {
    @Binding var decor: TextDecor?
    @Binding var fontFamily: String?
    var inherited: TextDecor = .defaults
    var defaultLabel = "Inherited"
    var boxOnly = false
    var defaultMaxWidth = 1.0
    /// The element's shared-style link, when the surface has one; a linked
    /// source then pastes its link plus overrides instead of a flat look.
    var sharedStyleID: Binding<String?>? = nil
    /// Names the element in the Paste tooltip and the saved style's name.
    var sourceLabel = "text"
    @Environment(AppStore.self) private var store
    /// Bumped after a copy so Paste enables at once; other editors catch up on their next render.
    @State private var clipboardTick = 0

    private var resolved: TextDecor { (decor ?? TextDecor()).resolved(over: inherited) }
    private var clipboard: TextStylePayload? { _ = clipboardTick; return TextStyleClipboard.read() }
    /// A box-only surface (the caption page, the name-tag box) has nothing but a background to paste.
    private var pasteGroups: [TextStyleClipboard.Group] { boxOnly ? [.background] : TextStyleClipboard.Group.allCases }

    private func copyStyle() {
        TextStyleClipboard.write(TextStyleClipboard.payload(stored: decor, inherited: inherited, fontFamily: fontFamily,
                                                            sharedStyleID: sharedStyleID?.wrappedValue, source: sourceLabel))
        clipboardTick += 1
    }

    private func pasteStyle(_ groups: Set<TextStyleClipboard.Group>) {
        guard let clipboard else { return }
        let pasted = TextStyleClipboard.pasted(clipboard, onto: decor, groups: groups, linkShared: sharedStyleID != nil)
        decor = pasted.decor
        if let link = pasted.sharedStyleID { sharedStyleID?.wrappedValue = link }
        if groups.contains(.typography), !boxOnly { fontFamily = pasted.fontFamily }
    }

    private func saveAsNamedStyle() {
        let payload = TextStyleClipboard.payload(stored: decor, inherited: inherited, fontFamily: fontFamily,
                                                 sharedStyleID: nil, source: sourceLabel)
        let existing = Set((store.activeProfile.textStyles ?? []).map(\.name))
        var name = "\(sourceLabel.prefix(1).uppercased())\(sourceLabel.dropFirst()) style"
        var number = 2
        while existing.contains(name) { name = "\(sourceLabel.prefix(1).uppercased())\(sourceLabel.dropFirst()) style \(number)"; number += 1 }
        store.activeProfile.textStyles = (store.activeProfile.textStyles ?? [])
            + [NamedTextStyle(name: name, decor: payload.look, fontFamily: payload.fontFamily)]
    }

    /// Copy Style / Paste Style / Save as Named Text Style, on every surface.
    private var clipboardRow: some View {
        HStack(spacing: Theme.spaceS) {
            Button("Copy Style", systemImage: "doc.on.doc", action: copyStyle)
                .lineLimit(1).fixedSize()
                .help("Copy this \(sourceLabel)'s look (font, fill, stroke, shadow, background) to paste onto another text element, in this or another profile.")
            Menu {
                Button("Everything") { pasteStyle(Set(pasteGroups)) }
                if pasteGroups.count > 1 {
                    Divider()
                    ForEach(pasteGroups, id: \.self) { group in
                        Button("\(group.label) only") { pasteStyle([group]) }
                    }
                }
            } label: {
                Label("Paste Style", systemImage: "doc.on.clipboard")
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(clipboard == nil)
            .help(clipboard.map { "Paste the style copied from \($0.source). Placement is never pasted." } ?? "Copy a style first.")
            if !boxOnly {
                Button("Save as Named Text Style", systemImage: "square.and.arrow.down", action: saveAsNamedStyle)
                    .lineLimit(1).fixedSize()
                    .help("Add this look to the profile's Named Text Styles so any caption, name tag or overlay can share it.")
            }
        }
        .onAppear { clipboardTick += 1 }
    }

    private func setting<Value>(_ key: WritableKeyPath<TextDecor, Value?>, _ fallback: Value) -> Binding<Value> {
        Binding(get: { TextDecorEditing.value(key, stored: decor, inherited: inherited) ?? fallback },
                set: { decor = TextDecorEditing.setting(key, to: $0, in: decor) })
    }

    private func help(_ key: String) -> String { WizardFieldHelp.textDecor[key]?.tooltip ?? "" }

    private func reset<Value>(_ key: WritableKeyPath<TextDecor, Value?>) -> some View {
        Button {
            decor = TextDecorEditing.setting(key, to: nil, in: decor)
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .buttonStyle(.borderless)
        .disabled(decor?[keyPath: key] == nil)
        .help("Use \(defaultLabel.lowercased()) value")
        .accessibilityLabel("Use \(defaultLabel.lowercased()) value")
    }

    private func number(_ label: String, _ key: WritableKeyPath<TextDecor, Double?>,
                        _ id: String, _ range: ClosedRange<Double>) -> some View {
        // A labelled slider draws its track over the label in a narrow
        // inspector; LabeledContent reserves the label's width first.
        LabeledContent {
            HStack {
                Slider(value: setting(key, key == \.maxWidthFrac ? defaultMaxWidth : range.lowerBound), in: range)
                Text(setting(key, key == \.maxWidthFrac ? defaultMaxWidth : range.lowerBound).wrappedValue, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit().lineLimit(1).fixedSize().frame(width: 44)
                reset(key)
            }
        } label: {
            Text(label).lineLimit(1).fixedSize()
        }
        .help(help(id))
    }

    private func toggle(_ label: String, _ key: WritableKeyPath<TextDecor, Bool?>, _ id: String) -> some View {
        HStack {
            Toggle(isOn: setting(key, false)) { Text(label).lineLimit(1).fixedSize() }
            reset(key)
        }.help(help(id))
    }

    private func color(_ label: String, _ key: WritableKeyPath<TextDecor, String?>, _ id: String) -> some View {
        HStack {
            ColorPicker(selection: overlayColorBinding(setting(key, "#ffffff")), supportsOpacity: false) {
                Text(label).lineLimit(1).fixedSize()
            }
            reset(key)
        }.help(help(id))
    }

    private func choices(_ label: String, _ key: WritableKeyPath<TextDecor, String?>,
                         _ id: String, _ values: [(String, String)]) -> some View {
        HStack {
            Picker(selection: setting(key, values[0].0)) {
                ForEach(values, id: \.0) { value in
                    Text(value.1).lineLimit(1).fixedSize().tag(value.0)
                }
            } label: { Text(label).lineLimit(1).fixedSize() }
            reset(key)
        }.help(help(id))
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            clipboardRow
            clipboardRow.labelStyle(.iconOnly)
        }
        if !boxOnly {
            FontFamilyPicker(family: $fontFamily, defaultLabel: defaultLabel).help(help("font"))
            number("Size", \.size, "size", 0.1...4)
            choices("Weight", \.weight, "weight", [("regular", "Regular"), ("bold", "Bold"), ("black", "Black")])
            LabeledContent {
                TextStyleBar(bold: Binding(get: { resolved.weight != "regular" }, set: { decor = TextDecorEditing.setting(\.weight, to: $0 ? "bold" : "regular", in: decor) }),
                    italic: setting(\.italic, false), underline: setting(\.underline, false), strikethrough: setting(\.strikethrough, false))
                Button("Reset") {
                    var value = decor ?? TextDecor()
                    value.weight = nil; value.italic = nil; value.underline = nil; value.strikethrough = nil
                    decor = value
                }.lineLimit(1).fixedSize()
            } label: { Text("Style").lineLimit(1).fixedSize() }
            .help(help("style"))
            if resolved.underline == true {
                TextDecorDependentRows {
                    color("Underline colour", \.underlineColor, "underlineColor")
                    number("Underline thickness", \.underlineThickness, "underlineThickness", 0.01...0.3)
                }
            }
            choices("Casing", \.casing, "casing", [("asWritten", "As written"), ("upper", "UPPERCASE"), ("lower", "lowercase"), ("title", "Title Case")])
            color("Fill colour", \.color, "color")
            HStack {
                Toggle(isOn: Binding(get: { resolved.fillEndColor != nil }, set: {
                    var value = decor ?? TextDecor()
                    value.gradientOn = $0
                    if $0 && resolved.fillEndColor == nil { value.fillEndColor = "#ffd60a" }
                    decor = value
                })) { Text("Gradient").lineLimit(1).fixedSize() }.help(help("gradient"))
                reset(\.gradientOn)
            }
            if resolved.fillEndColor != nil {
                TextDecorDependentRows {
                    color("End colour", \.fillEndColor, "fillEndColor")
                    number("Angle", \.fillAngle, "fillAngle", 0...360)
                }
            }
            number("Text opacity", \.textOpacity, "textOpacity", 0...1)
            toggle("Stroke", \.strokeOn, "strokeOn")
            if resolved.strokeOn == true {
                TextDecorDependentRows {
                    number("Stroke width", \.strokeWidth, "strokeWidth", 0...6)
                    color("Stroke colour", \.strokeColor, "strokeColor")
                    number("Stroke opacity", \.strokeOpacity, "strokeOpacity", 0...1)
                }
            }
            toggle("Shadow", \.shadowOn, "shadowOn")
            if resolved.shadowOn == true {
                TextDecorDependentRows {
                    HStack {
                        Picker(selection: Binding(
                            get: { TextShadowPresets.matching((decor ?? TextDecor()).resolved(over: inherited))?.name ?? "" },
                            set: { name in
                                guard let preset = TextShadowPresets.all.first(where: { $0.name == name }) else { return }
                                decor = TextShadowPresets.apply(preset, to: decor)
                            })) {
                            Text("Custom").tag("")
                            ForEach(TextShadowPresets.all) { preset in
                                Text(preset.name).lineLimit(1).fixedSize().tag(preset.name).help(preset.help)
                            }
                        } label: { Text("Shadow preset").lineLimit(1).fixedSize() }
                    }.help(help("shadowPreset"))
                    color("Shadow colour", \.shadowColor, "shadowColor")
                    number("Shadow opacity", \.shadowOpacity, "shadowOpacity", 0...1)
                    choices("Shadow style", \.shadowStyle, "shadowStyle", [("soft", "Soft"), ("hard", "Hard"), ("extrude", "3D extrude")])
                    number("Shadow X", \.shadowX, "shadowX", -3...3)
                    number("Shadow Y", \.shadowY, "shadowY", -3...3)
                    if resolved.shadowStyle == "soft" {
                        number("Shadow blur", \.shadowBlur, "shadowBlur", 0...3)
                    }
                }
            }
        }
        toggle("Background", \.bgOn, "bgOn")
        if resolved.bgOn == true {
            TextDecorDependentRows {
                color("Background colour", \.bgColor, "bgColor")
                number("Background opacity", \.bgOpacity, "bgOpacity", 0...1)
                number("Corner radius", \.bgRadius, "bgRadius", 0...40)
                number("Padding X", \.bgPaddingX, "bgPaddingX", 0...3)
                number("Padding Y", \.bgPaddingY, "bgPaddingY", 0...3)
                toggle("Per line", \.bgPerLine, "bgPerLine")
            }
        }
        toggle("Border", \.borderOn, "borderOn")
        if resolved.borderOn == true {
            TextDecorDependentRows {
                number("Border width", \.borderWidth, "borderWidth", 0...6)
                color("Border colour", \.borderColor, "borderColor")
            }
        }
        if !boxOnly {
            number("Letter spacing", \.letterSpacing, "letterSpacing", -2...6)
            number("Line height", \.lineHeight, "lineHeight", 0.8...2)
            choices("Alignment", \.alignment, "alignment", [("leading", "Left"), ("center", "Center"), ("trailing", "Right")])
            number("Max width", \.maxWidthFrac, "maxWidthFrac", 0.2...1)
        }
    }
}

/// Forms use the caption-indent environment; the default keeps narrow inspectors usable.
private struct TextDecorDependentRows<Content: View>: View {
    @Environment(\.formCaptionIndent) private var indent
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) { content }
            .padding(.leading, max(Theme.spaceXL, indent))
    }
}
