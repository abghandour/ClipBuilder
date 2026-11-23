import Foundation

nonisolated enum StrikeImpactRender {
    /// Keep the old filter spelling for every previously supported speed.
    static func audioTempo(speed: Double) -> String {
        if speed >= StrikeImpactRules.minimumSpeed, speed < 0.5 {
            return String(format: "atempo=0.5000,atempo=%.4f,", speed / 0.5)
        }
        return speed == 1 ? "" : String(format: "atempo=%.4f,", min(2, max(0.5, speed)))
    }

    /// The fade uses screen seconds. Restore the source clock afterwards so
    /// camera paths and the existing downstream speed stage keep their clocks.
    static func flash(_ seconds: Double?, speed: Double, hold: Bool) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let fade = String(format: "fade=t=in:st=0:d=%.6f:color=white", seconds)
        if hold { return "fps=30,setpts=PTS-STARTPTS," + fade }
        if speed == 1 { return "setpts=PTS-STARTPTS," + fade }
        return String(format: "setpts=(PTS-STARTPTS)/%.4f,", speed) + fade
            + String(format: ",setpts=PTS*%.4f", speed)
    }
}
