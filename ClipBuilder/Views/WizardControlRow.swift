import SwiftUI

extension EnvironmentValues {
    @Entry var wizardStepRows = false
}

/// Opt-in alignment for shared controls used outside a Form. Existing Forms and
/// Express retain their own layout. Narrow panes stack instead of wrapping labels.
struct WizardControlRow<Content: View>: View {
    @Environment(\.wizardStepRows) private var usesStepRows
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if usesStepRows {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceL) {
                    label
                    Spacer(minLength: Theme.spaceM)
                    control
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    label
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
        content.labelsHidden()
            .lineLimit(1).fixedSize()
    }
}
