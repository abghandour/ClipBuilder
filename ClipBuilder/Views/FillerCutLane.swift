import SwiftUI

/// Under a reel's scrubber: one mark where each filler cut lands.
struct FillerCutLane: View {
    let markers: [FillerCutRules.Marker]
    let duration: Double

    var body: some View {
        // Drawn under the scrubber on its scale: the thumb above is the playhead.
        GeometryReader { geometry in
            let width = geometry.size.width
            let scale = duration > 0 ? width / duration : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.6))
                ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                    RoundedRectangle(cornerRadius: 1).fill(Color.orange)
                        .frame(width: 3, height: 8)
                        .offset(x: min(max(0, marker.time * scale - 1.5), max(0, width - 3)))
                }
            }
        }
        .allowsHitTesting(false)
        .help("Where filler words were cut")
        .accessibilityLabel("Filler cuts")
        .accessibilityValue(FillerCutRules.summary(markers) ?? "None")
    }
}
