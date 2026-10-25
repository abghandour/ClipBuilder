import SwiftUI

/// "Looks not shown" reminder for fast previews. Over the monitor it may
/// wrap; in a controls bar it must stay one line: given a sliver of width
/// there, the wrapped label once grew to hundreds of points tall, made the
/// bar taller than the timeline pane, and pushed the ruler and lanes below
/// the window — the "tracks disappear" report after composing a grid.
struct LooksPreviewBadge: View {
    /// One line, shrinking to the icon alone when the row is crowded.
    var inline = false

    var body: some View {
        if inline {
            ViewThatFits(in: .horizontal) {
                label.lineLimit(1).fixedSize()
                Image(systemName: "sparkles")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, Theme.spaceS)
                    .padding(.vertical, Theme.spaceXS)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
                    .accessibilityLabel("Effects not shown — use Render Preview")
            }
            .help(Self.helpText)
        } else {
            label
                .fixedSize(horizontal: false, vertical: true)
                .help(Self.helpText)
        }
    }

    private static let helpText = "Fast previews omit effects. Render Preview uses the same effect processing as the final export."

    private var label: some View {
        Label("Effects not shown — use Render Preview", systemImage: "sparkles")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, Theme.spaceS)
            .padding(.vertical, Theme.spaceXS)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
    }
}
