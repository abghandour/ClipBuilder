import SwiftUI

extension EnvironmentValues {
    @Entry var wizardStepRows = false
}

/// Opt-in alignment for shared controls used outside a Form. Existing Forms and
/// Express retain their own layout.
struct WizardControlRow<Content: View>: View {
    @Environment(\.wizardStepRows) private var usesStepRows
    @Environment(\.settingsLabelWidth) private var labelWidth
    let title: String
    var detail: String?
    @ViewBuilder let content: Content

    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        if usesStepRows {
            // One label column for every row of a step, so every control
            // starts on the same x; a long label wraps inside the column.
            // The explanation goes under the control, never beside it.
            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.spaceM) {
                    label.frame(width: labelWidth, alignment: .trailing)
                    control.frame(maxWidth: SettingsRowMetrics.controlWidth, alignment: .leading)
                    Spacer(minLength: 0)
                }
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, labelWidth + Theme.spaceM)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
        }
    }

    private var label: some View {
        Text(title)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true) // Native control still owns its accessible label.
    }

    private var control: some View {
        // Width stays flexible so sliders fill the column; height hugs the control.
        content.labelsHidden()
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
    }
}
