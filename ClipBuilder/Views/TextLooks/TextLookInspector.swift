import SwiftUI

/// A surface describes the sparse bindings and parent for each editable state.
struct TextLookSurface {
    struct State: Identifiable {
        var id: String
        var decor: Binding<TextDecor?>
        var fontFamily: Binding<String?>
        var inherited: TextDecor = .defaults
        var parent = "Inherited"
        var boxOnly = false
        var maxWidth = 1.0
        var sharedStyleID: Binding<String?>? = nil
        var source = "text"
    }
    enum Sample { case captions, tags, overlay, named }
    var states: [State]
    var selection: Binding<String>
    var sample: Sample

    var selected: State { states.first { $0.id == selection.wrappedValue } ?? states[0] }
}

/// The same inspector on the studio and embedded text surfaces.
struct TextLookInspector<Controls: View>: View {
    let surface: TextLookSurface
    @ViewBuilder var controls: Controls
    @Environment(AppStore.self) private var store
    @State private var clipboardTick = 0

    private var state: TextLookSurface.State { surface.selected }
    private var decor: TextDecor? {
        get { state.decor.wrappedValue }
        nonmutating set { state.decor.wrappedValue = newValue }
    }
    private var fontFamily: String? {
        get { state.fontFamily.wrappedValue }
        nonmutating set { state.fontFamily.wrappedValue = newValue }
    }
    private var inherited: TextDecor { state.inherited }
    private var boxOnly: Bool { state.boxOnly }
    private var sharedStyleID: Binding<String?>? { state.sharedStyleID }
    private var sourceLabel: String { state.source }
    private var clipboard: TextStylePayload? {
        _ = clipboardTick
        return TextStyleClipboard.read()
    }
    private var pasteGroups: [TextStyleClipboard.Group] { boxOnly ? [.background] : TextStyleClipboard.Group.allCases }

    private var namedStyles: [NamedTextStyle] { store.activeProfile.textStyles ?? [] }

    /// A look is "in use" when the state links to it, or stores exactly its values.
    private func isUsing(_ named: NamedTextStyle) -> Bool {
        if let sharedStyleID { return sharedStyleID.wrappedValue == named.id.uuidString }
        return decor == named.decor && (boxOnly || fontFamily == named.fontFamily)
    }

    private func use(_ named: NamedTextStyle) {
        if let sharedStyleID {
            sharedStyleID.wrappedValue = named.id.uuidString
        } else {
            decor =
                boxOnly
                ? TextStyleClipboard.pasted(
                    TextStyleClipboard.payload(
                        stored: named.decor, inherited: .defaults,
                        fontFamily: named.fontFamily, sharedStyleID: nil, source: named.name),
                    onto: decor, groups: [.background], linkShared: false
                ).decor : named.decor
            if !boxOnly { fontFamily = named.fontFamily }
        }
    }

    private func apply(_ preset: NamedCaptionStyle) {
        let payload = TextStyleClipboard.payload(
            stored: preset.style.resolvedTextDecor(for: .text),
            inherited: .defaults, fontFamily: preset.style.fontOverride ?? preset.style.font, sharedStyleID: nil,
            source: preset.name)
        let pasted = TextStyleClipboard.pasted(payload, onto: decor, groups: Set(pasteGroups), linkShared: false)
        decor = pasted.decor
        if !boxOnly { fontFamily = pasted.fontFamily }
    }

    private var lookChoices: [LookChoice] {
        var choices: [LookChoice] = []
        if let sharedStyleID {
            choices.append(
                LookChoice(
                    id: "none", name: "None", isSelected: sharedStyleID.wrappedValue == nil,
                    help: "No shared style; this element keeps only its own values."
                ) { sharedStyleID.wrappedValue = nil })
        }
        choices += namedStyles.map { named in
            LookChoice(
                id: named.id.uuidString, name: named.name, decor: named.decor, fontFamily: named.fontFamily,
                isSelected: isUsing(named), help: "Use \(named.name)"
            ) { use(named) }
        }
        choices += CaptionPresets.styles.map { preset in
            LookChoice(
                id: "preset:\(preset.name)", name: preset.name, decor: preset.style.resolvedTextDecor(for: .text),
                fontFamily: preset.style.fontOverride ?? preset.style.font,
                help: "Apply the \(preset.name) look to this state"
            ) { apply(preset) }
        }
        return choices
    }

    private var overrideCount: Int {
        boxOnly
            ? TextLookSummary.overrideCount(decor, prefix: "bg") + TextLookSummary.overrideCount(decor, prefix: "border")
            : TextLookSummary.overrideCount(decor) + (fontFamily == nil ? 0 : 1)
    }

    private var hint: String {
        if boxOnly { return "\(state.id) is the box behind the words. Tinted labels mark what it sets." }
        return "\(state.id) starts from \(state.parent). Tinted labels mark what this state changes."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceL) {
            // A single-state surface (an overlay, a named style) has nothing to switch.
            if surface.states.count > 1 {
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    Picker("State", selection: surface.selection) {
                        ForEach(surface.states) { state in
                            Text(state.id).lineLimit(1).tag(state.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    // Equal-width segments: four regular-size segments do not fit a 320 pt pane,
                    // and a segment wider than the pane pushes the whole column off-centre.
                    .controlSize(.small)
                    .labelsHidden()
                    .help("Choose which text state to edit. Other states keep their own overrides.")
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            controls
            TextLookSection("Look", trailing: { clipboardRow }) {
                // The grid is the picker; the popup only surfaces a link to a style that no longer exists.
                if let sharedStyleID, let id = sharedStyleID.wrappedValue, !namedStyles.contains(where: { $0.id.uuidString == id }) {
                    SharedTextStylePicker(selection: sharedStyleID).labelsHidden()
                }
                LookTileGrid(choices: lookChoices)
            }
            .help(WizardFieldHelp.textDecor["look"]!.tooltip)
            TextLookInspectorSections(
                decor: state.decor, fontFamily: state.fontFamily,
                inherited: inherited, defaultLabel: state.parent, boxOnly: boxOnly, defaultMaxWidth: state.maxWidth)
            Divider()
            HStack(spacing: Theme.spaceS) {
                Text(overrideCount == 1 ? "1 override" : "\(overrideCount) overrides")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button("Reset state to \(state.parent.lowercased())") {
                    if boxOnly {
                        decor = TextLookSummary.resetBox(in: decor)
                    } else {
                        decor = nil
                        fontFamily = nil
                    }
                }
                .lineLimit(1).fixedSize().disabled(overrideCount == 0)
                .help("Remove this state's local overrides and use its parent look.")
            }
        }
    }

    private func copyStyle() {
        TextStyleClipboard.write(
            TextStyleClipboard.payload(
                stored: decor, inherited: inherited, fontFamily: fontFamily,
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
        let payload = TextStyleClipboard.payload(
            stored: decor, inherited: inherited, fontFamily: fontFamily,
            sharedStyleID: nil, source: sourceLabel)
        let existing = Set((store.activeProfile.textStyles ?? []).map(\.name))
        var name = "\(sourceLabel.prefix(1).uppercased())\(sourceLabel.dropFirst()) style"
        var number = 2
        while existing.contains(name) {
            name = "\(sourceLabel.prefix(1).uppercased())\(sourceLabel.dropFirst()) style \(number)"
            number += 1
        }
        store.activeProfile.textStyles =
            (store.activeProfile.textStyles ?? [])
            + [NamedTextStyle(name: name, decor: payload.look, fontFamily: payload.fontFamily)]
        store.scheduleActiveProfileSave()
    }

    /// Copy Style / Paste Style / Save as Named Text Style, on every surface.
    private var clipboardRow: some View {
        ControlGroup {
            Button("Copy Style", systemImage: "doc.on.doc", action: copyStyle)
                .lineLimit(1).fixedSize()
                .help(
                    "Copy this \(sourceLabel)'s look (font, fill, stroke, shadow, background) to paste onto another text element, in this or another profile."
                )
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
            Button("Save as Named Text Style", systemImage: "square.and.arrow.down", action: saveAsNamedStyle)
                .lineLimit(1).fixedSize()
                .help("Add this look to the profile's Named Text Styles so any caption, name tag or overlay can share it.")
        }
        .labelStyle(.iconOnly)
        .onAppear { clipboardTick += 1 }
    }

}

extension TextLookInspector where Controls == EmptyView {
    init(
        decor: Binding<TextDecor?>, fontFamily: Binding<String?>, inherited: TextDecor = .defaults,
        defaultLabel: String = "Inherited", boxOnly: Bool = false, defaultMaxWidth: Double = 1,
        sharedStyleID: Binding<String?>? = nil, sourceLabel: String = "text", stateLabel: String = "Text"
    ) {
        surface = TextLookSurface(
            states: [
                .init(
                    id: stateLabel, decor: decor, fontFamily: fontFamily,
                    inherited: inherited, parent: defaultLabel, boxOnly: boxOnly, maxWidth: defaultMaxWidth,
                    sharedStyleID: sharedStyleID, source: sourceLabel)
            ], selection: .constant(stateLabel), sample: .overlay)
        controls = EmptyView()
    }
}
