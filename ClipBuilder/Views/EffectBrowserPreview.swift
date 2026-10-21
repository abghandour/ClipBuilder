import SwiftUI

/// Give the portrait player the remaining pane height; small panes scroll
/// instead of forcing the parent split view taller than its window.
struct EffectBrowserPreview<Preview: View, Details: View>: View {
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let details: () -> Details
    @State private var detailsHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let previewHeight = max(360, geometry.size.height - detailsHeight - Theme.spaceM)
            ScrollView {
                VStack(spacing: Theme.spaceM) {
                    preview()
                        .aspectRatio(9.0 / 16, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
                        .frame(maxWidth: .infinity, maxHeight: previewHeight)
                        .frame(height: previewHeight)
                    details()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
    }
}
