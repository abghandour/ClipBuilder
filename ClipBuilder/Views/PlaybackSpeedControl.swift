import AVFoundation
import SwiftUI

/// The speed selector beside every custom Play button: a speedometer and
/// the current speed, opening a menu of speeds like a native player's. One
/// remembered choice (`PlaybackSpeed.key`) for every player in the app.
struct PlaybackSpeedControl: View {
    @Binding var rate: Double

    /// A trim surface: the playback snaps, stores and applies the rate itself.
    init(playback: PodcastHighlightTrimPlayback) {
        _rate = Binding(get: { playback.rate }, set: { playback.setRate($0) })
    }

    /// Any other player: the owner applies the rate (see `AVPlayer.setReviewSpeed`).
    /// Pass an `@AppStorage(PlaybackSpeed.key)` binding so the choice is shared.
    init(rate: Binding<Double>) {
        _rate = Binding(get: { PlaybackSpeed.nearest(rate.wrappedValue) },
                        set: { rate.wrappedValue = PlaybackSpeed.nearest($0) })
    }

    var body: some View {
        Menu {
            ForEach(PlaybackSpeed.presets, id: \.self) { value in
                Button {
                    rate = value
                } label: {
                    if value == rate {
                        Label(PlaybackSpeed.label(value), systemImage: "checkmark")
                    } else {
                        Text(PlaybackSpeed.label(value))
                    }
                }
            }
        } label: {
            Label(PlaybackSpeed.label(rate), systemImage: PlaybackSpeed.symbol(rate))
                .font(.callout.monospacedDigit())
                .lineLimit(1)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed, \(PlaybackSpeed.label(PlaybackSpeed.range.lowerBound)) to \(PlaybackSpeed.label(PlaybackSpeed.range.upperBound)). Remembered for every player in the app.")
        .accessibilityLabel("Playback speed")
        .accessibilityValue(PlaybackSpeed.label(rate))
    }
}

extension AVPlayer {
    /// The review speed for this player: `play()` uses it from now on, and a
    /// player already running changes speed on the spot.
    func setReviewSpeed(_ speed: Double) {
        let value = Float(PlaybackSpeed.nearest(speed))
        defaultRate = value
        if rate != 0, rate != value { rate = value }
    }
}
