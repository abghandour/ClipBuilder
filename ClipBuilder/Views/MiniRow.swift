import SwiftUI

/// Form-style alignment without a Form's capped content column.
struct MiniRow<Control: View>: View {
    let label: String
    let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        VStack(spacing: Theme.spaceS) {
            HStack(spacing: Theme.spaceM) {
                Text(label)
                    .lineLimit(1).fixedSize()
                    .accessibilityHidden(true) // The native control retains its own label.
                Spacer(minLength: 0)
                control
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
        }
    }
}

/// Rows that only exist because the row above them is switched on. The
/// indent (rules included) shows which setting they belong to.
struct MiniDependents<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            content
        }
        .padding(.leading, Theme.spaceXL)
    }
}
