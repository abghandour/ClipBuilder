import SwiftUI

/// Shared row treatment for the Reel and its Fight-metrics Footage picks.
struct StrikeClipStatusLine: View {
    var status: StrikeClipStatus?
    var fallback: String? = nil

    var body: some View {
        if let text = status?.line ?? fallback {
            Label(text, systemImage: (status?.pause ?? .off) == .off ? "viewfinder" : "snowflake")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .help(status?.help ?? text)
                // The owning row includes the full, untruncated status value.
                .accessibilityHidden(true)
        }
    }
}
