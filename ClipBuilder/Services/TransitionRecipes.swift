import Foundation

/// Action-pack transitions that go beyond a single xfade: each is rendered as
/// a short "bridge" segment built from the tail of the outgoing clip and the
/// head of the incoming clip, hard-cut into the timeline on both sides.
/// RenderEngine.concatenate() trims the adjoining clips by `pieces` and drops
/// the bridge in between, so every recipe except the ones with a nonzero
/// `consumedOverlap` preserves total timeline duration.
nonisolated enum TransitionRecipes {
    static let names = ["knife_slash", "zoom_punch", "whip_left", "whip_right",
                        "impact_shake", "glitch", "speed_ramp"]

    static func isRecipe(_ name: String?) -> Bool {
        guard let name else { return false }
        return names.contains(name)
    }

    /// Seconds consumed from the outgoing clip's end (tail) and the incoming
    /// clip's start (head) to build the bridge.
    static func pieces(for name: String) -> (tail: Double, head: Double) {
        switch name {
        case "knife_slash":  return (0.12, 0.26)
        case "zoom_punch":   return (0.18, 0.18)
        case "whip_left",
             "whip_right":   return (0.20, 0.20)
        case "impact_shake": return (0.00, 0.35)
        case "glitch":       return (0.00, 0.20)
        case "speed_ramp":   return (0.50, 0.00)
        default:             return (0, 0)
        }
    }

    /// Timeline seconds the bridge is SHORTER than tail + head — the whip's
    /// slide overlap and the speed ramp's compression eat real time, exactly
    /// like an xfade's overlap does.
    static func consumedOverlap(for name: String) -> Double {
        switch name {
        case "whip_left", "whip_right": return 0.15
        case "speed_ramp":              return 0.30
        default:                        return 0
        }
    }

    /// Render the bridge segment for `name`. `tailPiece`/`headPiece` are the
    /// already-extracted, normalized tail/head sub-clips (nil when the recipe
    /// consumes none of that side). `lastFrameA` is a PNG of the outgoing
    /// clip's final frame (knife_slash only). `sfx` is an optional sound
    /// effect mixed over the bridge audio.
    static func renderBridge(name: String, tailPiece: URL?, headPiece: URL?,
                             lastFrameA: URL?, sfx: URL?, output: URL) async throws {
        var arguments: [String] = ["-y"]
        var inputCount = 0
        func addInput(_ url: URL, options: [String] = []) -> Int {
            arguments += options + ["-i", url.path]
            defer { inputCount += 1 }
            return inputCount
        }

        let w = RenderEngine.outputWidth
        let h = RenderEngine.outputHeight
        var filters: [String] = []
        var audioOut = "[cat]"
        var sfxDelayMs = 0

        switch name {
        case "zoom_punch":
            guard let tail = tailPiece, let head = headPiece else { throw CocoaError(.featureUnsupported) }
            _ = addInput(tail)
            _ = addInput(head)
            // Outgoing crashes in (accelerating zoom), incoming settles back
            // out of a slight zoom with a 2-frame white flash on the cut.
            filters.append("[0:v]zoompan=z='1+0.6*pow(on/5,2)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
                           + ":d=1:s=\(w)x\(h):fps=30,format=yuv420p[za]")
            filters.append("[1:v]zoompan=z='1+0.4*pow(max(0,1-on/5),2)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
                           + ":d=1:s=\(w)x\(h):fps=30,"
                           + "fade=t=in:st=0:d=0.07:color=white,format=yuv420p[zb]")
            filters.append("[za][zb]concat=n=2:v=1:a=0[vout]")
            filters.append("[0:a][1:a]concat=n=2:v=0:a=1[cat]")
            sfxDelayMs = 60

        case "whip_left", "whip_right":
            guard let tail = tailPiece, let head = headPiece else { throw CocoaError(.featureUnsupported) }
            _ = addInput(tail)
            _ = addInput(head)
            let direction = name == "whip_left" ? "slideleft" : "slideright"
            // Fast slide + temporal smear reads as a camera whip-pan.
            filters.append("[0:v][1:v]xfade=transition=\(direction):duration=0.15:offset=0.05,"
                           + "tmix=frames=4[vout]")
            filters.append("[0:a][1:a]acrossfade=d=0.15[cat]")

        case "impact_shake":
            guard let head = headPiece else { throw CocoaError(.featureUnsupported) }
            _ = addInput(head)
            // Decaying jitter crop inside a 10% oversized frame — the hit lands.
            filters.append("[0:v]scale=1188:2112,"
                           + "crop=\(w):\(h):x='54+46*exp(-10*t)*sin(62*t)':y='96+46*exp(-9*t)*cos(47*t)'[vout]")
            filters.append("[0:a]anull[cat]")

        case "glitch":
            guard let head = headPiece else { throw CocoaError(.featureUnsupported) }
            _ = addInput(head)
            filters.append("[0:v]rgbashift=rh=10:rv=-6:gh=-4:bh=-10:bv=6,"
                           + "noise=alls=14:allf=t+u[vout]")
            filters.append("[0:a]anull[cat]")

        case "speed_ramp":
            guard let tail = tailPiece else { throw CocoaError(.featureUnsupported) }
            _ = addInput(tail)
            // 0.5s of outgoing footage accelerates 2.5x into the cut.
            filters.append("[0:v]setpts=PTS/2.5,fps=30[vout]")
            filters.append("[0:a]atempo=2.0,atempo=1.25[cat]")

        case "knife_slash":
            guard let tail = tailPiece, let head = headPiece, let frame = lastFrameA else {
                throw CocoaError(.featureUnsupported)
            }
            _ = addInput(tail)
            _ = addInput(head)
            let frameIndex = addInput(frame, options: ["-loop", "1", "-framerate", "30", "-t", "0.26"])
            // The "/" slash diagonal runs top-right → bottom-left: pixels with
            // X*h + Y*w < w*h sit above-left of it.
            let diag = "X*\(h)+Y*\(w)"
            let area = w * h
            // Phase 1 (0.12s): outgoing plays; a white slash line flashes over
            // its last frames.
            filters.append("color=white:s=\(w)x\(h):d=0.12:r=30,format=rgba,"
                           + "geq=r=255:g=255:b=255:a='if(lt(abs(\(diag)-\(area)),26000),255,0)'[line]")
            filters.append("[0:v][line]overlay=enable='gte(t,0.05)',format=yuv420p[pre]")
            // Phase 2 (0.26s): incoming plays underneath while the two halves
            // of the outgoing clip's frozen last frame slide apart along the
            // slash — accelerating so it snaps off screen.
            filters.append("[\(frameIndex):v]scale=\(w):\(h),setsar=1,format=rgba,split[fa1][fa2]")
            filters.append("[fa1]geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)'"
                           + ":a='if(lt(\(diag),\(area)),255,0)'[half1]")
            filters.append("[fa2]geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)'"
                           + ":a='if(gte(\(diag),\(area)),255,0)'[half2]")
            let progress = "pow(min(t/0.24,1),2)"
            filters.append("[1:v][half1]overlay=x='-2200*\(progress)':y='-1240*\(progress)'[s1]")
            filters.append("[s1][half2]overlay=x='2200*\(progress)':y='1240*\(progress)',format=yuv420p[s2]")
            filters.append("[pre][s2]concat=n=2:v=1:a=0[vout]")
            filters.append("[0:a][1:a]concat=n=2:v=0:a=1[cat]")
            sfxDelayMs = 40

        default:
            throw CocoaError(.featureUnsupported)
        }

        if let sfx {
            let sfxIndex = addInput(sfx)
            let delay = sfxDelayMs > 0 ? "adelay=\(sfxDelayMs)|\(sfxDelayMs)," : ""
            filters.append("[\(sfxIndex):a]\(delay)volume=0.8,"
                           + "aformat=sample_rates=44100:channel_layouts=stereo[sfx]")
            filters.append("\(audioOut)[sfx]amix=inputs=2:duration=first:normalize=0[aout]")
            audioOut = "[aout]"
        }

        try await FFmpeg.run(arguments + [
            "-filter_complex", filters.joined(separator: ";"),
            "-map", "[vout]", "-map", audioOut,
        ] + FFmpeg.encodeArgs + [output.path], timeout: 300)
    }
}

/// Procedurally synthesized transition sound effects — generated once per
/// launch into the render work directory with ffmpeg's lavfi sources, so no
/// binary assets ship with the app.
nonisolated enum TransitionSFX {
    enum Kind: String, CaseIterable {
        case whoosh, impact, slash
    }

    static func kind(for recipe: String) -> Kind? {
        switch recipe {
        case "whip_left", "whip_right", "speed_ramp": return .whoosh
        case "zoom_punch", "impact_shake":            return .impact
        case "knife_slash", "glitch":                 return .slash
        default:                                      return nil
        }
    }

    /// Generate (if needed) and return the WAV for `kind`. Returns nil when
    /// synthesis fails — bridges then render without sound.
    static func url(for kind: Kind, in directory: URL) async -> URL? {
        let file = directory.appendingPathComponent("sfx_\(kind.rawValue).wav")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let arguments: [String]
        switch kind {
        case .whoosh:
            arguments = ["-y", "-f", "lavfi", "-i", "anoisesrc=color=pink:duration=0.4:amplitude=0.8",
                         "-af", "bandpass=f=800:w=1000,afade=t=in:st=0:d=0.18,"
                              + "afade=t=out:st=0.22:d=0.18,volume=2.2"]
        case .impact:
            arguments = ["-y", "-f", "lavfi", "-i", "sine=frequency=52:duration=0.35",
                         "-f", "lavfi", "-i", "anoisesrc=color=white:duration=0.05:amplitude=0.6",
                         "-filter_complex", "[0:a]afade=t=out:st=0.02:d=0.33,volume=3[low];"
                              + "[1:a]lowpass=f=5000[click];"
                              + "[low][click]amix=inputs=2:duration=longest:normalize=0[aout]",
                         "-map", "[aout]"]
        case .slash:
            arguments = ["-y", "-f", "lavfi", "-i", "anoisesrc=color=white:duration=0.22:amplitude=0.8",
                         "-af", "highpass=f=2200,afade=t=in:st=0:d=0.02,"
                              + "afade=t=out:st=0.05:d=0.17,volume=1.8"]
        }
        guard (try? await FFmpeg.run(arguments + ["-ar", "44100", "-ac", "2", file.path],
                                     timeout: 60)) != nil else { return nil }
        return file
    }
}
