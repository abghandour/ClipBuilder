import SwiftUI

/// The speed control that sits beside a trim surface's Play button. One
/// remembered choice for every trim surface.
struct PlaybackSpeedSlider: View {
    let playback: PodcastHighlightTrimPlayback

    var body: some View {
        HStack(spacing: Theme.spaceXS) {
            // Continuous track, no tick marks: the playback snaps the value to
            // quarter-speed stops, so the thumb still lands on them.
            Slider(value: Binding(
                get: { playback.rate },
                set: { playback.setRate($0) }),
                in: PlaybackSpeed.range)
                .controlSize(.small)
                .frame(width: 84)
                .accessibilityLabel("Playback speed")
                .accessibilityValue(PlaybackSpeed.label(playback.rate))
                .help("Playback speed, \(PlaybackSpeed.label(PlaybackSpeed.range.lowerBound)) to \(PlaybackSpeed.label(PlaybackSpeed.range.upperBound)). Remembered for every trim player.")
            Button(PlaybackSpeed.label(playback.rate)) { playback.setRate(1) }
                .buttonStyle(.plain)
                .font(.caption.monospacedDigit())
                .foregroundStyle(playback.rate == 1 ? .secondary : .primary)
                .lineLimit(1)
                .frame(width: 36, alignment: .leading)
                .help("Back to normal speed")
        }
        .fixedSize()
    }
}
