import SwiftUI

extension EnvironmentValues {
    @Entry var wizardStepRows = false
}

/// Opt-in alignment for shared controls used outside a Form. Existing Forms and
/// Express retain their own layout. Narrow panes stack instead of wrapping labels.
struct WizardControlRow<Content: View>: View {
    @Environment(\.wizardStepRows) private var usesStepRows
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.spaceM) {
                    // minWidth: a label longer than the column widens its own row instead of being clipped.
                    label.frame(minWidth: SettingsRowMetrics.labelWidth, alignment: .trailing)
                    control.frame(maxWidth: detail == nil ? SettingsRowMetrics.controlWidth : nil, alignment: .leading)
                    if let detail {
                        SettingsRowDetail(detail)
                    }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    label
                    if let detail {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content.labelsHidden()
                        .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
        }
    }

    private var label: some View {
        Text(title).lineLimit(1).fixedSize()
            .accessibilityHidden(true) // Native control still owns its accessible label.
    }

    private var control: some View {
        // Width stays flexible so sliders fill the column; height hugs the control.
        content.labelsHidden()
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
    }
}
