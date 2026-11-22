import AVKit
import SwiftUI

struct FightActionPreview: View {
    @Bindable var playback: FightActionPlayback
    var hdTrack: StrikeHighlightRules.Track?
    var hdBusy: Bool
    /// The selected strike's HD highlight is being made right now.
    var hdWorking = false
    var makeHD: () -> Void
    @AppStorage("analyze.fight.loop") private var loop = true
    @AppStorage("analyze.fight.strikeHighlight") private var highlight = true
    @AppStorage("analyze.fight.pauseOnImpact") private var pauseOnImpact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                PlayerView(player: playback.player, controlsStyle: .none)
                if highlight, let track = playback.highlight {
                    StrikeHighlightOverlay(player: playback.player, track: track)
                }
                if let error = playback.error { Text(error).padding().background(.regularMaterial) }
            }
            .aspectRatio(16.0 / 9, contentMode: .fit)
            .frame(maxHeight: 260)
            HStack {
                Button("Previous frame", systemImage: "backward.frame") { playback.step(-1) }.labelStyle(.iconOnly)
                Button(playback.playing ? "Pause" : "Play", systemImage: playback.playing ? "pause.fill" : "play.fill") {
                    playback.togglePlay()
                }.labelStyle(.iconOnly)
                Button("Next frame", systemImage: "forward.frame") { playback.step(1) }.labelStyle(.iconOnly)
                Text(playback.time.timecode).monospacedDigit()
                Spacer()
                Picker("Speed", selection: $playback.speed) {
                    Text("0.25×").tag(Float(0.25))
                    Text("0.5×").tag(Float(0.5))
                    Text("1×").tag(Float(1))
                }.frame(width: 120)
            }
            .disabled(playback.player == nil)
            HStack {
                Toggle("Loop", isOn: $loop)
                Toggle("Highlight", isOn: $highlight)
                Toggle("Pause on impact", isOn: $pauseOnImpact)
            }.toggleStyle(.button).controlSize(.small)
            HStack(spacing: 6) {
                Button(hdTrack?.isHD == true ? "HD ✓" : "HD", systemImage: "sparkles.rectangle.stack", action: makeHD)
                    .lineLimit(1).fixedSize()
                    .disabled(hdBusy || hdTrack == nil || hdTrack?.isHD == true)
                    .help("Follow the striking limb's outline in the picture. Runs in the background; Stop is in the job row.")
                if hdWorking { ProgressView().controlSize(.small) }
            }
            if highlight, playback.highlightMissing {
                Label("No highlight for this strike: the limb could not be followed in the picture. Pause on impact uses the scored time.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .lineLimit(1).fixedSize(horizontal: false, vertical: true)
        .onAppear { syncOptions() }
        .onChange(of: loop) { syncOptions() }
        .onChange(of: highlight) { syncOptions() }
        .onChange(of: pauseOnImpact) { syncOptions() }
    }

    private func syncOptions() {
        playback.loop = loop
        playback.showHighlight = highlight
        playback.pauseOnImpact = pauseOnImpact
    }
}
