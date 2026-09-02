import SwiftUI

/// A player's current time as its own observable object, so the 10 Hz
/// periodic observer invalidates only the leaf views that read it — not the
/// whole editor that owns the player. Hold it in `@State`, write from the
/// observer, and read through `ClockReader` / `ClockKeyedTask`.
@Observable
final class PlaybackClock {
    var time = 0.0

    /// Store a tick, skipping identical values (a paused player keeps
    /// ticking the same time).
    func update(_ seconds: Double) {
        guard seconds.isFinite, seconds != time else { return }
        time = seconds
    }
}

/// Renders `content` with the clock's time; only this view re-evaluates
/// when the time changes.
struct ClockReader<Content: View>: View {
    let clock: PlaybackClock
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        content(clock.time)
    }
}

/// A zero-size view that runs `action` whenever the clock's half-second
/// bucket or `extra` changes — a `.task(id:)` whose id reads the clock
/// without dragging the parent body into the dependency.
struct ClockKeyedTask: View {
    let clock: PlaybackClock
    let extra: String
    let action: @MainActor (Double) async -> Void

    var body: some View {
        let key = "\(extra)|\((clock.time * 2).rounded())"
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: key) { await action(clock.time) }
    }
}
