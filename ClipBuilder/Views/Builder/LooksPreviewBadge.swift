import SwiftUI

struct LooksPreviewBadge: View {
    var body: some View {
        Label("Looks not shown — use Render Preview", systemImage: "camera.filters")
            .font(.caption2.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.spaceS)
            .padding(.vertical, Theme.spaceXS)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
            .help("Fast previews omit looks. Render Preview uses the same look processing as the final export.")
    }
}
