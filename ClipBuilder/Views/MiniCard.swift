import SwiftUI

/// A Mini step keeps its summary and reopening action visible when collapsed.
struct MiniCard<Content: View>: View {
    let number: Int
    let title: String
    let summary: String
    let isOpen: Bool
    var compactSummary = false
    var change: (() -> Void)? = nil
    /// Clicking the header toggles the card when the caller provides this.
    var headerTap: (() -> Void)? = nil
    /// Small controls at the header's trailing edge (e.g. Save / Load).
    var accessory: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            HStack(spacing: Theme.spaceM) {
                if let headerTap {
                    Button(action: headerTap) {
                        HStack(spacing: Theme.spaceS) {
                            heading
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(number) \(title)")
                    .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                    .accessibilityHint("Click to \(isOpen ? "collapse" : "expand")")
                    .help(isOpen ? "Collapse \(title)" : "Expand \(title)")
                } else {
                    heading
                }
                if let change, !isOpen {
                    Spacer(minLength: Theme.spaceS)
                    Button("Change", action: change)
                        .lineLimit(1).fixedSize()
                        .accessibilityLabel("Change \(title)")
                }
                if let accessory {
                    Spacer(minLength: Theme.spaceS)
                    accessory
                }
            }
            if !isOpen {
                if compactSummary {
                    Text(summary)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(summary)
                } else {
                    FormCaption(summary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spaceL)
        .background(.quaternary, in: .rect(cornerRadius: Theme.cardRadius))
    }

    private var heading: some View {
        Text("\(number) \(title)")
            .font(.headline)
            .lineLimit(1).fixedSize()
            .accessibilityAddTraits(.isHeader)
    }
}
