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
    static let labelWidth: CGFloat = 100

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
        HStack(spacing: Theme.spaceS) {
            self.label(label, key)
            Slider(value: bounded(key, range), in: range).accessibilityLabel(label)
            TextField(label, value: bounded(key, range), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).monospacedDigit().multilineTextAlignment(.trailing).frame(width: 50)
                .accessibilityLabel(label)
        }
        .help(help(id))
    }

    private func offsetField(_ axis: String, _ key: WritableKeyPath<TextDecor, Double?>) -> some View {
        HStack(spacing: 4) {
            Text(axis).font(.caption).foregroundStyle(.secondary).frame(width: 12)
            TextField(axis, value: bounded(key, -3...3), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).monospacedDigit().multilineTextAlignment(.trailing).frame(width: 56)
                .accessibilityLabel("Shadow offset \(axis)")
        }
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
            TextField(label, text: setting(key, "#ffffff"))
                .textFieldStyle(.roundedBorder).monospaced().frame(width: 84)
                .accessibilityLabel("\(label) hex")
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
            TextLookSection("Font") {
                HStack(spacing: Theme.spaceS) {
                    OverrideLabel(text: "Family", isSet: fontFamily != nil, parent: defaultLabel) { fontFamily = nil }
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
            TextLookSection("Colour") {
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
        }
        TextLookSection("Effects") {
            if !boxOnly {
                effect("Stroke", \.strokeOn, "strokeOn", TextLookSummary.stroke(resolved)) {
                    number("Width", \.strokeWidth, "strokeWidth", 0...6)
                    color("Colour", \.strokeColor, "strokeColor")
                    number("Opacity", \.strokeOpacity, "strokeOpacity", 0...1)
                }
                effect("Shadow", \.shadowOn, "shadowOn", TextLookSummary.shadow(resolved, stored: decor)) {
                    // Neutral white samples: a tile shows the shadow, not this state's box or stroke.
                    LookTileGrid(
                        choices: TextShadowPresets.all.map { preset in
                            LookChoice(
                                id: preset.name,
                                name: preset.name.replacingOccurrences(of: " drop", with: "")
                                    .replacingOccurrences(of: " offset", with: "").replacingOccurrences(of: " shadow", with: ""),
                                decor: TextShadowPresets.apply(preset, to: nil).resolved(over: .defaults),
                                isSelected: TextShadowPresets.matching(resolved)?.name == preset.name, help: preset.help
                            ) { decor = TextShadowPresets.apply(preset, to: decor) }
                        })
                    .help(help("shadowPreset"))
                    color("Colour", \.shadowColor, "shadowColor")
                    number("Opacity", \.shadowOpacity, "shadowOpacity", 0...1)
                    choices("Style", \.shadowStyle, "shadowStyle", [("soft", "Soft"), ("hard", "Hard"), ("extrude", "3D extrude")])
                    HStack(alignment: .center, spacing: Theme.spaceS) {
                        OverrideLabel(
                            text: "Offset", isSet: decor?.shadowX != nil || decor?.shadowY != nil, parent: defaultLabel
                        ) {
                            var value = decor ?? TextDecor()
                            value.shadowX = nil
                            value.shadowY = nil
                            decor = value
                        }
                        ShadowOffsetPad(x: setting(\.shadowX, 0), y: setting(\.shadowY, -0.08))
                        VStack(alignment: .leading, spacing: 4) {
                            offsetField("X", \.shadowX)
                            offsetField("Y", \.shadowY)
                        }
                        Spacer(minLength: 0)
                    }.help(help("shadowOffset"))
                    if resolved.shadowStyle == "soft" {
                        number("Blur", \.shadowBlur, "shadowBlur", 0...3)
                    }
                }
            }
            effect("Box", \.bgOn, "bgOn", TextLookSummary.box(resolved, perWord: !boxOnly)) {
                color("Colour", \.bgColor, "bgColor")
                number("Opacity", \.bgOpacity, "bgOpacity", 0...1)
                number("Radius", \.bgRadius, "bgRadius", 0...40)
                number("Padding X", \.bgPaddingX, "bgPaddingX", 0...3)
                number("Padding Y", \.bgPaddingY, "bgPaddingY", 0...3)
                toggle("Per line", \.bgPerLine, "bgPerLine")
            }
            effect("Border", \.borderOn, "borderOn", TextLookSummary.border(resolved)) {
                number("Width", \.borderWidth, "borderWidth", 0...6)
                color("Colour", \.borderColor, "borderColor")
            }
        }
        if !boxOnly {
            TextLookSection("Spacing") {
                number("Letter spacing", \.letterSpacing, "letterSpacing", -2...6)
                number("Line height", \.lineHeight, "lineHeight", 0.8...2)
                choices("Alignment", \.alignment, "alignment", [("leading", "Left"), ("center", "Center"), ("trailing", "Right")])
                number("Max width", \.maxWidthFrac, "maxWidthFrac", 0.2...1)
            }
        }
    }
}

/// A plain inspector row for settings that are not decor overrides (caption
/// paging, tag fields): the label sits in the shared column, the control after it.
struct TextLookRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: Theme.spaceS) {
            Text(label).lineLimit(1).fixedSize().frame(width: TextLookInspectorSections.labelWidth, alignment: .leading)
            control.labelsHidden()
            Spacer(minLength: 0)
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

/// A flat section: a small tracked uppercase header, then the rows. The
/// optional trailing view sits on the header line (the Look row's buttons).
struct TextLookSection<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(spacing: Theme.spaceS) {
                SectionLabel(title)
                Spacer(minLength: 0)
                trailing
            }
            content
        }
    }
}

extension TextLookSection where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, trailing: { EmptyView() }, content: content)
    }
}

/// An effect card: chevron, title, one-line summary and the on/off switch on
/// the header; the rows appear inside the card when it is expanded.
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.spaceS) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: Theme.spaceS) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 12)
                        Text(title).font(.body.weight(.semibold)).lineLimit(1).fixedSize()
                            .foregroundStyle(overridden ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                        Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(summary)")
                .accessibilityValue(expanded ? "expanded" : "collapsed")
                .contextMenu { Button("Use \(parent.lowercased()) value", action: reset).disabled(!overridden) }
                Toggle(title, isOn: $enabled).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel("\(title) on")
            }
            .padding(.horizontal, Theme.spaceM).padding(.vertical, Theme.spaceS)
            if expanded {
                VStack(alignment: .leading, spacing: 10) { content }
                    .disabled(!enabled)
                    .padding(.horizontal, Theme.spaceM).padding(.bottom, Theme.spaceM)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
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
