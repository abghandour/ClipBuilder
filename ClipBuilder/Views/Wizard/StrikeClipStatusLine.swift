import SwiftUI

/// Shared row treatment for the Reel and its Fight-metrics Footage picks.
struct StrikeClipStatusLine: View {
    var status: StrikeClipStatus?
    var fallback: String? = nil
    var symbol: String = "viewfinder"

    var body: some View {
        if let text = status?.line ?? fallback {
            Label(text, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                // A list row is narrow: "drawing over the moving picture" needs its second line.
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .help(status?.help ?? text)
                // The owning row includes the full, untruncated status value.
                .accessibilityHidden(true)
        }
    }
}
