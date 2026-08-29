import Foundation

/// One transition effect as the app presents it: the engine name the
/// timeline and planner carry, a human title, what it looks like, and its
/// family. The Effects section lists these, the Builder's pickers show
/// their titles, and the AI Wizard's prompt is generated from them — so a
/// new effect is added in ONE place (plus its recipe, when it isn't a
/// plain xfade).
nonisolated struct TransitionEffect: Identifiable, Sendable, Hashable {
    enum Category: String, CaseIterable, Sendable {
        case cut, action, flash, crossfade

        var title: String {
            switch self {
            case .cut: return "Cut"
            case .action: return "Action"
            case .flash: return "Flash"
            case .crossfade: return "Crossfade"
            }
        }

        var blurb: String {
            switch self {
            case .cut: return "The backbone of fast-paced editing."
            case .action: return "Aggressive accents for the biggest moments — rendered as short bridge segments from the outgoing and incoming footage."
            case .flash: return "Two-frame flash cuts: a punctuation mark, not a fade."
            case .crossfade: return "Softer, slower blends between clips (ffmpeg xfade). Their length is the crossfade duration in Settings."
            }
        }
    }

    /// Engine name ("knife_slash", "fadeblack", "cut").
    var name: String
    var title: String
    var description: String
    var category: Category

    var id: String { name }

    /// Seconds of timeline the effect eats at the gap (see
    /// RenderEngine.consumedOverlap) — the number shown on its card.
    func consumedOverlap(xfadeDuration: Double) -> Double {
        RenderEngine.consumedOverlap(name == "cut" ? nil : name, xfadeDuration: xfadeDuration)
    }
}

nonisolated enum TransitionCatalog {
    static let cut = TransitionEffect(
        name: "cut", title: "Hard Cut",
        description: "No effect — the next clip starts on the next frame. Use it for most gaps in high-energy content.",
        category: .cut)

    static let action: [TransitionEffect] = [
        TransitionEffect(name: "knife_slash", title: "Knife Slash",
                         description: "A blade slashes the screen diagonally; the two halves of the outgoing frame slide apart to reveal the next clip underneath.",
                         category: .action),
        TransitionEffect(name: "zoom_punch", title: "Zoom Punch",
                         description: "The outgoing clip crashes in with an accelerating zoom, a white flash frame lands on the cut, and the incoming clip settles back out of a slight zoom.",
                         category: .action),
        TransitionEffect(name: "whip_left", title: "Whip Pan Left",
                         description: "A fast slide to the left with motion smear — reads as a camera whip-pan into the next shot.",
                         category: .action),
        TransitionEffect(name: "whip_right", title: "Whip Pan Right",
                         description: "The same whip-pan, sliding to the right.",
                         category: .action),
        TransitionEffect(name: "impact_shake", title: "Impact Shake",
                         description: "The incoming clip opens with a decaying camera shake — pair it with a hit landing.",
                         category: .action),
        TransitionEffect(name: "glitch", title: "Glitch",
                         description: "RGB channel split and digital noise over the first frames of the incoming clip.",
                         category: .action),
        TransitionEffect(name: "speed_ramp", title: "Speed Ramp",
                         description: "The last half-second of the outgoing clip accelerates 2.5× into the cut.",
                         category: .action),
    ]

    static let flashes: [TransitionEffect] = [
        TransitionEffect(name: "flash_white", title: "White Flash",
                         description: "A two-frame flash to white on the cut.", category: .flash),
        TransitionEffect(name: "flash_black", title: "Black Flash",
                         description: "A two-frame dip to black on the cut.", category: .flash),
    ]

    /// Every xfade the engine accepts, in RenderEngine.transitions order.
    static let crossfades: [TransitionEffect] = {
        let titles: [String: (String, String)] = [
            "fade": ("Fade", "Straight dissolve from one clip to the next."),
            "fadeblack": ("Fade Through Black", "The outgoing clip fades to black, the incoming fades up from it."),
            "fadewhite": ("Fade Through White", "Fades through white instead of black — brighter, dreamier."),
            "wipeleft": ("Wipe Left", "A hard edge sweeps right-to-left, revealing the next clip."),
            "wiperight": ("Wipe Right", "A hard edge sweeps left-to-right."),
            "wipeup": ("Wipe Up", "A hard edge sweeps bottom-to-top."),
            "wipedown": ("Wipe Down", "A hard edge sweeps top-to-bottom."),
            "slideleft": ("Slide Left", "The incoming clip pushes the outgoing one off to the left."),
            "slideright": ("Slide Right", "The incoming clip pushes the outgoing one off to the right."),
            "circlecrop": ("Circle Crop", "The outgoing clip shrinks into a circle over black, then the incoming grows out of one."),
            "circleopen": ("Circle Open", "An expanding circle reveals the next clip from the center."),
            "circleclose": ("Circle Close", "A shrinking circle closes on the outgoing clip."),
            "radial": ("Radial", "A clock-hand sweep reveals the next clip."),
            "dissolve": ("Dissolve", "Pixel-noise dissolve between the clips."),
            "smoothleft": ("Smooth Left", "A soft-edged wipe to the left."),
            "smoothright": ("Smooth Right", "A soft-edged wipe to the right."),
            "diagtl": ("Diagonal (Top-Left)", "A diagonal wipe from the top-left corner."),
            "diagbr": ("Diagonal (Bottom-Right)", "A diagonal wipe from the bottom-right corner."),
            "horzopen": ("Horizontal Open", "Splits open from the middle, top and bottom moving apart."),
            "horzclose": ("Horizontal Close", "Closes from top and bottom toward the middle."),
            "vertopen": ("Vertical Open", "Splits open from the middle, left and right moving apart."),
            "vertclose": ("Vertical Close", "Closes from left and right toward the middle."),
            "hlslice": ("Horizontal Slices", "Horizontal strips flip over one after another."),
            "hrslice": ("Horizontal Slices (Reverse)", "The same strip reveal, running the other way."),
            "zoomin": ("Zoom In", "The outgoing clip zooms in and dissolves into the next."),
            "coverleft": ("Cover Left", "The incoming clip slides in from the right and covers the outgoing one."),
            "coverright": ("Cover Right", "The incoming clip slides in from the left and covers the outgoing one."),
            "revealleft": ("Reveal Left", "The outgoing clip slides away to the left, uncovering the next."),
            "revealright": ("Reveal Right", "The outgoing clip slides away to the right, uncovering the next."),
            "pixelize": ("Pixelize", "Both clips break into blocks through the change."),
        ]
        return RenderEngine.transitions.map { name in
            let entry = titles[name] ?? (name.capitalized, "ffmpeg xfade \"\(name)\".")
            return TransitionEffect(name: name, title: entry.0, description: entry.1, category: .crossfade)
        }
    }()

    /// Everything, in display order: cut, action pack, flashes, crossfades.
    static let all: [TransitionEffect] = [cut] + action + flashes + crossfades

    static func effect(named name: String?) -> TransitionEffect? {
        guard let name else { return nil }
        return all.first { $0.name == name }
    }

    /// Display title for a timeline/plan transition name ("cut" and nil are
    /// both the hard cut).
    static func title(for name: String?) -> String {
        effect(named: name ?? "cut")?.title ?? (name ?? "Hard Cut")
    }

    /// The planner's "Available Transitions" block, generated from the
    /// catalog so a new effect reaches the AI without editing the prompt.
    /// `allowed` restricts it to the user's picks (hard cut always stays).
    static func promptBlock(allowed: [String]? = nil) -> String {
        var lines: [String] = []
        lines.append("Hard cut: \"cut\" — \(cut.description)")
        if let allowed {
            let picked = Set(allowed)
            let chosen = (action + flashes + crossfades).filter { picked.contains($0.name) }
            if chosen.isEmpty {
                lines.append("The user allowed NO other transitions — every gap is \"cut\".")
            } else {
                lines.append("The user limited this reel to these transitions — use ONLY these names:")
                for effect in chosen {
                    lines.append("- \"\(effect.name)\" (\(effect.category.title.lowercased())) — \(effect.description)")
                }
            }
            return lines.joined(separator: "\n")
        }
        lines.append("Action transitions (aggressive accents for combat/sports/high-energy moments):")
        for effect in action + flashes {
            lines.append("- \"\(effect.name)\" — \(effect.description)")
        }
        lines.append("Crossfades (softer, slower): " + crossfades.map(\.name).joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    static var promptBlock: String { promptBlock(allowed: nil) }
}

/// Which footage the Effects previews are built from: the two synthetic
/// test cards by default, or a still frame from a video of the user's
/// choosing on each side. Persisted in UserDefaults so the choice sticks.
nonisolated struct EffectSampleSet: Sendable, Equatable {
    var videoA: URL?
    var videoB: URL?

    static let defaultsKeyA = "effects.sampleA"
    static let defaultsKeyB = "effects.sampleB"

    static var saved: EffectSampleSet {
        let defaults = UserDefaults.standard
        func url(_ key: String) -> URL? {
            guard let path = defaults.string(forKey: key), !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        return EffectSampleSet(videoA: url(defaultsKeyA), videoB: url(defaultsKeyB))
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(videoA?.path ?? "", forKey: Self.defaultsKeyA)
        defaults.set(videoB?.path ?? "", forKey: Self.defaultsKeyB)
    }

    var isDefault: Bool { videoA == nil && videoB == nil }

    /// Short stable tag for cache file names — the samples' paths and
    /// modification dates, so re-picking a file re-renders.
    var cacheTag: String {
        guard !isDefault else { return "cards" }
        func stamp(_ url: URL?) -> String {
            guard let url else { return "card" }
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            return "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)"
        }
        var hasher = Hasher()
        hasher.combine(stamp(videoA))
        hasher.combine(stamp(videoB))
        return String(UInt(bitPattern: hasher.finalize()), radix: 36)
    }
}

/// Renders a looping sample of each effect — two cards (synthetic test
/// cards, or stills from the user's chosen videos) run through the SAME
/// pipeline a real render uses (RenderEngine.concatenate, so bridges,
/// flashes and xfades all look exactly as they will in a reel) — cached
/// under the assets folder so each effect renders once per sample set.
nonisolated enum EffectPreviewRenderer {
    /// Bump when the test cards or timing change, so stale previews re-render.
    private static let version = 2

    static var directory: URL {
        ProfileStore.profilesDirectory.appendingPathComponent("assets/effects/previews", isDirectory: true)
    }

    static func previewURL(for effect: TransitionEffect, samples: EffectSampleSet = .saved) -> URL {
        directory.appendingPathComponent("\(effect.name)-v\(version)-\(samples.cacheTag).mp4")
    }

    static func hasPreview(for effect: TransitionEffect, samples: EffectSampleSet = .saved) -> Bool {
        FileManager.default.fileExists(atPath: previewURL(for: effect, samples: samples).path)
    }

    /// Render (if missing) and return the preview clip for `effect`.
    static func preview(for effect: TransitionEffect,
                        samples: EffectSampleSet = .saved) async throws -> URL {
        let output = previewURL(for: effect, samples: samples)
        if FileManager.default.fileExists(atPath: output.path) { return output }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb_effect_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let cardA = scratch.appendingPathComponent("a.mp4")
        let cardB = scratch.appendingPathComponent("b.mp4")
        if let video = samples.videoA {
            try await stillCard(from: video, scratch: scratch, label: "a", output: cardA)
        } else {
            try await testCard(color: "0x2563EB", shape: .square, output: cardA)
        }
        if let video = samples.videoB {
            try await stillCard(from: video, scratch: scratch, label: "b", output: cardB)
        } else {
            try await testCard(color: "0xEA580C", shape: .bars, output: cardB)
        }
        let render = RenderEngine()
        let joined = scratch.appendingPathComponent("joined.mp4")
        try await render.concatenate(clips: [cardA, cardB],
                                     transitions: [effect.name == "cut" ? nil : effect.name],
                                     output: joined)
        try FileManager.default.copyItemReplacing(at: joined, to: output)
        return output
    }

    /// Delete every cached preview (all sample sets) — the Reset button.
    static func clearCache() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "mp4" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private enum Shape { case square, bars }

    static let cardDuration = 1.1

    /// A 1.1s card holding one still frame (the video's midpoint) fitted
    /// into 1080x1920, with silent audio.
    private static func stillCard(from video: URL, scratch: URL, label: String, output: URL) async throws {
        let duration = await FFmpeg.duration(of: video)
        let still = scratch.appendingPathComponent("still_\(label).png")
        try await FFmpeg.run(["-y", "-ss", String(format: "%.2f", max(0, duration / 2)),
                              "-i", video.path, "-frames:v", "1", "-update", "1", still.path],
                             timeout: 60)
        let w = RenderEngine.outputWidth
        let h = RenderEngine.outputHeight
        let filter = "[0:v]scale=\(w):\(h):force_original_aspect_ratio=decrease,"
            + "pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=30,format=yuv420p[vout]"
        var arguments: [String] = ["-y", "-loop", "1", "-t", String(format: "%.2f", cardDuration),
                                   "-i", still.path,
                                   "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                                   "-filter_complex", filter,
                                   "-map", "[vout]", "-map", "1:a",
                                   "-t", String(format: "%.2f", cardDuration)]
        arguments += FFmpeg.encodeArgs
        arguments.append(output.path)
        try await FFmpeg.run(arguments, timeout: 120)
    }

    /// A 1.1s 1080x1920 card: solid color with a white mark so movement,
    /// zoom, and slicing all read; silent stereo audio for the recipes'
    /// audio concat.
    private static func testCard(color: String, shape: Shape, output: URL) async throws {
        let w = RenderEngine.outputWidth
        let h = RenderEngine.outputHeight
        var marks: [String]
        switch shape {
        case .square:
            marks = ["drawbox=x=\(w / 2 - 300):y=\(h / 2 - 300):w=600:h=600:color=white@0.92:t=fill",
                     "drawbox=x=\(w / 2 - 180):y=\(h / 2 - 180):w=360:h=360:color=\(color):t=fill"]
        case .bars:
            marks = ["drawbox=x=\(w / 2 - 320):y=\(h / 2 - 340):w=640:h=140:color=white@0.92:t=fill",
                     "drawbox=x=\(w / 2 - 320):y=\(h / 2 - 70):w=640:h=140:color=white@0.92:t=fill",
                     "drawbox=x=\(w / 2 - 320):y=\(h / 2 + 200):w=640:h=140:color=white@0.92:t=fill"]
        }
        // A thin border so slides/wipes show the frame edge moving.
        marks.append("drawbox=x=24:y=24:w=\(w - 48):h=\(h - 48):color=white@0.5:t=8")
        let video = "color=c=\(color):s=\(w)x\(h):d=\(cardDuration):r=30"
        let filter = "[0:v]" + marks.joined(separator: ",") + ",setsar=1,fps=30[vout]"
        var arguments: [String] = ["-y", "-f", "lavfi", "-i", video,
                                   "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                                   "-filter_complex", filter,
                                   "-map", "[vout]", "-map", "1:a",
                                   "-t", String(format: "%.2f", cardDuration)]
        arguments += FFmpeg.encodeArgs
        arguments.append(output.path)
        try await FFmpeg.run(arguments, timeout: 120)
    }
}
