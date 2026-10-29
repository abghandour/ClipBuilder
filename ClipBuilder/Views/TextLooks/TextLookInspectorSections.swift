import SwiftUI

struct TextLookInspectorSections: View {
    @Binding var decor: TextDecor?
    @Binding var fontFamily: String?
    var inherited: TextDecor
    var defaultLabel: String
    var boxOnly: Bool
    var defaultMaxWidth: Double
    private var resolved: TextDecor { (decor ?? TextDecor()).resolved(over: inherited) }

    /// Every row puts its label in this column so the controls line up.
    static let labelWidth: CGFloat = 92

    private func bounded(_ key: WritableKeyPath<TextDecor, Double?>, _ range: ClosedRange<Double>) -> Binding<Double> {
        let binding = setting(key, key == \.maxWidthFrac ? defaultMaxWidth : range.lowerBound)
        return Binding(
            get: { binding.wrappedValue },
            set: {
                guard $0.isFinite else { return }
                binding.wrappedValue = min(range.upperBound, max(range.lowerBound, $0))
            })
    }

    private func effect<Content: View>(
        _ title: String, _ key: WritableKeyPath<TextDecor, Bool?>,
        _ id: String, _ summary: String, @ViewBuilder content: () -> Content
    ) -> some View {
        EffectSection(
            title: title, enabled: setting(key, false), summary: summary,
            overridden: decor?[keyPath: key] != nil, parent: defaultLabel,
            reset: { decor = TextDecorEditing.setting(key, to: nil, in: decor) }, content: content
        )
        .help(help(id))
    }
    private func setting<Value>(_ key: WritableKeyPath<TextDecor, Value?>, _ fallback: Value) -> Binding<Value> {
        Binding(
            get: { TextDecorEditing.value(key, stored: decor, inherited: inherited) ?? fallback },
            set: { decor = TextDecorEditing.setting(key, to: $0, in: decor) })
    }

    private func help(_ key: String) -> String { WizardFieldHelp.textDecor[key]?.tooltip ?? "" }

    /// The row label. Tinted when this state sets the value; its context menu
    /// restores the parent value. The footer's Reset covers the whole state.
    private func label<Value>(_ text: String, _ key: WritableKeyPath<TextDecor, Value?>) -> some View {
        OverrideLabel(text: text, isSet: decor?[keyPath: key] != nil, parent: defaultLabel) {
            decor = TextDecorEditing.setting(key, to: nil, in: decor)
        }
    }

    private func number(
        _ label: String, _ key: WritableKeyPath<TextDecor, Double?>,
        _ id: String, _ range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.spaceS) {
                self.label(label, key)
                Spacer(minLength: 4)
                TextField(label, value: bounded(key, range), format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 52)
                    .accessibilityLabel(label)
            }
            Slider(value: bounded(key, range), in: range).accessibilityLabel(label)
        }
        .help(help(id))
    }

    private func toggle(_ label: String, _ key: WritableKeyPath<TextDecor, Bool?>, _ id: String) -> some View {
        HStack(spacing: Theme.spaceS) {
            self.label(label, key)
            Toggle(label, isOn: setting(key, false)).labelsHidden()
            Spacer(minLength: 0)
        }.help(help(id))
    }

    private func color(_ label: String, _ key: WritableKeyPath<TextDecor, String?>, _ id: String) -> some View {
        HStack(spacing: Theme.spaceS) {
            self.label(label, key)
            ColorPicker(label, selection: overlayColorBinding(setting(key, "#ffffff")), supportsOpacity: false).labelsHidden()
            Spacer(minLength: 0)
        }.help(help(id))
    }

    private func choices(
        _ label: String, _ key: WritableKeyPath<TextDecor, String?>,
        _ id: String, _ values: [(String, String)]
    ) -> some View {
        HStack(spacing: Theme.spaceS) {
            self.label(label, key)
            Picker(label, selection: setting(key, values[0].0)) {
                ForEach(values, id: \.0) { value in
                    Text(value.1).lineLimit(1).fixedSize().tag(value.0)
                }
            }.labelsHidden()
            Spacer(minLength: 0)
        }.help(help(id))
    }

    var body: some View {
        if !boxOnly {
            FontSection {
                HStack(spacing: Theme.spaceS) {
                    OverrideLabel(text: "Font", isSet: fontFamily != nil, parent: defaultLabel) { fontFamily = nil }
                    FontFamilyPicker(family: $fontFamily, label: "", defaultLabel: defaultLabel).labelsHidden().help(help("font"))
                    Spacer(minLength: 0)
                }
                number("Size", \.size, "size", 0.1...4)
                choices("Weight", \.weight, "weight", [("regular", "Regular"), ("bold", "Bold"), ("black", "Black")])
                HStack(spacing: Theme.spaceS) {
                    OverrideLabel(
                        text: "Style",
                        isSet: decor?.weight != nil || decor?.italic != nil || decor?.underline != nil || decor?.strikethrough != nil,
                        parent: defaultLabel
                    ) {
                        var value = decor ?? TextDecor()
                        value.weight = nil
                        value.italic = nil
                        value.underline = nil
                        value.strikethrough = nil
                        decor = value
                    }
                    TextStyleBar(
                        bold: Binding(
                            get: { resolved.weight != "regular" },
                            set: { decor = TextDecorEditing.setting(\.weight, to: $0 ? "bold" : "regular", in: decor) }),
                        italic: setting(\.italic, false), underline: setting(\.underline, false),
                        strikethrough: setting(\.strikethrough, false))
                    Spacer(minLength: 0)
                }
                .help(help("style"))
                if resolved.underline == true {
                    TextDecorDependentRows {
                        color("Underline colour", \.underlineColor, "underlineColor")
                        number("Underline thickness", \.underlineThickness, "underlineThickness", 0.01...0.3)
                    }
                }
                choices(
                    "Casing", \.casing, "casing",
                    [("asWritten", "As written"), ("upper", "UPPERCASE"), ("lower", "lowercase"), ("title", "Title Case")])
            }
            ColourSection {
                color("Fill colour", \.color, "color")
                HStack(spacing: Theme.spaceS) {
                    label("Gradient", \.gradientOn)
                    Toggle(
                        "Gradient",
                        isOn: Binding(
                            get: { resolved.fillEndColor != nil },
                            set: {
                                var value = decor ?? TextDecor()
                                value.gradientOn = $0
                                if $0 && resolved.fillEndColor == nil { value.fillEndColor = "#ffd60a" }
                                decor = value
                            })
                    ).labelsHidden()
                    Spacer(minLength: 0)
                }.help(help("gradient"))
                if resolved.fillEndColor != nil {
                    TextDecorDependentRows {
                        color("End colour", \.fillEndColor, "fillEndColor")
                        number("Angle", \.fillAngle, "fillAngle", 0...360)
                    }
                }
                number("Text opacity", \.textOpacity, "textOpacity", 0...1)
            }
            effect("Stroke", \.strokeOn, "strokeOn", TextLookSummary.stroke(resolved)) {
                number("Stroke width", \.strokeWidth, "strokeWidth", 0...6)
                color("Stroke colour", \.strokeColor, "strokeColor")
                number("Stroke opacity", \.strokeOpacity, "strokeOpacity", 0...1)
            }
            effect("Shadow", \.shadowOn, "shadowOn", TextLookSummary.shadow(resolved, stored: decor)) {
                HStack(spacing: Theme.spaceS) {
                    OverrideLabel(
                        text: "Preset", isSet: TextLookSummary.overrideCount(decor, prefix: "shadow") > 0, parent: defaultLabel
                    ) {
                        var value = decor ?? TextDecor()
                        TextStyleClipboard.copy(.shadow, from: TextDecor(), into: &value)
                        decor = value
                    }
                    Picker(
                        "Shadow preset",
                        selection: Binding(
                            get: { TextShadowPresets.matching((decor ?? TextDecor()).resolved(over: inherited))?.name ?? "" },
                            set: { name in
                                guard let preset = TextShadowPresets.all.first(where: { $0.name == name }) else { return }
                                decor = TextShadowPresets.apply(preset, to: decor)
                            })
                    ) {
                        Text("Custom").tag("")
                        ForEach(TextShadowPresets.all) { preset in
                            Text(preset.name).lineLimit(1).fixedSize().tag(preset.name).help(preset.help)
                        }
                    }.labelsHidden()
                    Spacer(minLength: 0)
                }.help(help("shadowPreset"))
                color("Shadow colour", \.shadowColor, "shadowColor")
                number("Shadow opacity", \.shadowOpacity, "shadowOpacity", 0...1)
                choices("Shadow style", \.shadowStyle, "shadowStyle", [("soft", "Soft"), ("hard", "Hard"), ("extrude", "3D extrude")])
                HStack(alignment: .top, spacing: Theme.spaceS) {
                    ShadowOffsetPad(x: setting(\.shadowX, 0), y: setting(\.shadowY, -0.08))
                    VStack(spacing: Theme.spaceS) {
                        number("X", \.shadowX, "shadowX", -3...3)
                        number("Y", \.shadowY, "shadowY", -3...3)
                    }
                }.help(help("shadowOffset"))
                if resolved.shadowStyle == "soft" {
                    number("Shadow blur", \.shadowBlur, "shadowBlur", 0...3)
                }
            }
        }
        effect("Box", \.bgOn, "bgOn", TextLookSummary.box(resolved, perWord: !boxOnly)) {
            color("Box colour", \.bgColor, "bgColor")
            number("Box opacity", \.bgOpacity, "bgOpacity", 0...1)
            number("Corner radius", \.bgRadius, "bgRadius", 0...40)
            number("Padding X", \.bgPaddingX, "bgPaddingX", 0...3)
            number("Padding Y", \.bgPaddingY, "bgPaddingY", 0...3)
            toggle("Per line", \.bgPerLine, "bgPerLine")
        }
        effect("Border", \.borderOn, "borderOn", TextLookSummary.border(resolved)) {
            number("Border width", \.borderWidth, "borderWidth", 0...6)
            color("Border colour", \.borderColor, "borderColor")
        }
        if !boxOnly {
            SpacingSection {
                number("Letter spacing", \.letterSpacing, "letterSpacing", -2...6)
                number("Line height", \.lineHeight, "lineHeight", 0.8...2)
                choices("Alignment", \.alignment, "alignment", [("leading", "Left"), ("center", "Center"), ("trailing", "Right")])
                number("Max width", \.maxWidthFrac, "maxWidthFrac", 0.2...1)
            }
        }
    }
}

/// A row label that is tinted when this state sets the value. Its context
/// menu restores the parent value; the visible path is the footer's Reset.
struct OverrideLabel: View {
    let text: String
    let isSet: Bool
    let parent: String
    let reset: () -> Void

    var body: some View {
        Text(text)
            .lineLimit(1).fixedSize()
            .foregroundStyle(isSet ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .frame(width: TextLookInspectorSections.labelWidth, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Use \(parent.lowercased()) value", action: reset).disabled(!isSet)
            }
            .help(isSet ? "Set here. Right-click to use the \(parent.lowercased()) value." : "")
            .accessibilityLabel(isSet ? "\(text), overrides \(parent)" : text)
    }
}

struct FontSection<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) { content }
        } label: {
            Text("Font").lineLimit(1).fixedSize()
        }
    }
}
struct ColourSection<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) { content }
        } label: {
            Text("Colour").lineLimit(1).fixedSize()
        }
    }
}
struct SpacingSection<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) { content }
        } label: {
            Text("Spacing").lineLimit(1).fixedSize()
        }
    }
}
struct EffectSection<Content: View>: View {
    let title: String
    @Binding var enabled: Bool
    let summary: String
    let overridden: Bool
    let parent: String
    let reset: () -> Void
    @ViewBuilder var content: Content
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) { content }.disabled(!enabled)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $enabled) {
                    Text(title).lineLimit(1).fixedSize()
                        .foregroundStyle(overridden ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                }
                .contextMenu { Button("Use \(parent.lowercased()) value", action: reset).disabled(!overridden) }
                if !expanded {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct TextDecorDependentRows<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 10) { content }.padding(.leading, 8) }
}

/// Numeric entry uses the same finite range as its adjacent slider.
func clampedTextLookNumber(_ value: Binding<Double>, in range: ClosedRange<Double>) -> Binding<Double> {
    Binding(
        get: { value.wrappedValue },
        set: {
            guard $0.isFinite else { return }
            value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0))
        })
}
