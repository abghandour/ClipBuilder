import SwiftUI

/// Form-style alignment without a Form's capped content column.
struct MiniRow<Control: View>: View {
    @Environment(\.settingsLabelWidth) private var labelWidth
    let label: String
    /// One line to the right of the control, truncated before it squeezes the control.
    var detail: String?
    let control: Control

    init(_ label: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        VStack(spacing: Theme.spaceS) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.spaceM) {
                Text(label)
                    .lineLimit(1).fixedSize()
                    // Natural width, so a dependent group can size its column to its longest label.
                    .overlay { GeometryReader { proxy in
                        Color.clear.preference(key: SettingsLabelWidthKey.self, value: proxy.size.width)
                    } }
                    .frame(minWidth: labelWidth, alignment: .trailing)
                    .accessibilityHidden(true) // The native control retains its own label.
                // A row with a detail hugs its menu so the text sits beside it, not past the column.
                control
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: detail == nil ? SettingsRowMetrics.controlWidth : nil, alignment: .leading)
                if let detail {
                    SettingsRowDetail(detail)
                }
                Spacer(minLength: 0)
            }
            Divider()
        }
    }
}

/// A labelled row for controls shared by Express and the Full wizard: an
/// Express MiniRow by default, the Full wizard's step row inside its steps.
struct SettingsRow<Control: View>: View {
    @Environment(\.wizardStepRows) private var usesStepRows
    let label: String
    var detail: String?
    let control: Control

    init(_ label: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        if usesStepRows {
            WizardControlRow(label, detail: detail) { control }
        } else {
            MiniRow(label, detail: detail) { control }
        }
    }
}

/// The explanation beside a row's control: secondary, one line, gives way first.
struct SettingsRowDetail: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .layoutPriority(-1)
            .help(text)
    }
}

/// Shared by Express rows and the Full wizard's step rows: labels end on one
/// column so every control starts at the same x and sits next to its label
/// instead of at the far edge of a wide panel.
enum SettingsRowMetrics {
    static let labelWidth: CGFloat = 150
    /// Sliders and text fields stop here; menus and pickers keep their natural size.
    static let controlWidth: CGFloat = 360
}

extension EnvironmentValues {
    /// The label column of the rows in scope; dependent groups narrow it to their longest label.
    @Entry var settingsLabelWidth: CGFloat = SettingsRowMetrics.labelWidth
}

/// The widest natural label width among the rows in a subtree.
struct SettingsLabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Rows that only exist because the row above them is switched on. The
/// indent (rules included) shows which setting they belong to: the group's
/// longest label starts where the parent row's control starts, and its
/// captions line up with its own controls.
struct MiniDependents<Content: View>: View {
    @Environment(\.settingsLabelWidth) private var parentLabelWidth
    @ViewBuilder let content: Content
    @State private var widestLabel: CGFloat = 0

    var body: some View {
        let column = widestLabel > 0 ? widestLabel : SettingsRowMetrics.labelWidth
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            content
        }
        .environment(\.settingsLabelWidth, column)
        .environment(\.formCaptionIndent, column + Theme.spaceM)
        .onPreferenceChange(SettingsLabelWidthKey.self) { widestLabel = $0 }
        // The group's labels do not widen an enclosing group's column.
        .preference(key: SettingsLabelWidthKey.self, value: 0)
        .padding(.leading, parentLabelWidth + Theme.spaceM)
    }
}
