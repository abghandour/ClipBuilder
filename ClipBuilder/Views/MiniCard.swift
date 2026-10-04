import SwiftUI

/// A Mini step keeps its summary and reopening action visible when collapsed.
struct MiniCard<Content: View>: View {
    let number: Int
    let title: String
    let summary: String
    let isOpen: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("\(number) \(title)")
                .font(.headline)
                .lineLimit(1).fixedSize()
                .accessibilityAddTraits(.isHeader)
            if !isOpen {
                FormCaption(summary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spaceL)
        .background(.quaternary, in: .rect(cornerRadius: Theme.cardRadius))
    }
}
