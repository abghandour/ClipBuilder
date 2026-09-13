import Foundation

/// Anchored edit grammar; scene searches resolve Library vocabulary and text
/// locally before requesting read-only assistance for unresolved terms.
@MainActor
struct BuilderRequestParser {
    static let supportedRequests = [
        "make track II black and white", "apply <preset name or id> to track N / this clip",
        "remove the look from track N / this clip",
        "remove (all) clips/scenes with <person>",
        "remove clips tagged <tag> [on track N]",
        "find <person> <tag> / find scenes of <person> <tag>",
        "cut/remove silence [longer than N s] on track N / in this clip",
        "add b-roll of <tag> at <time> [on track N] [for N s]",
        "split this clip at <time>", "trim this clip to N s",
        "mute/unmute this clip", "cover all areas",
        "set this clip speed to N x", "captions off for this clip", "set music volume to V",
        "set track N captions to none/top/middle/bottom", "mute/unmute track N",
        "remove clip N on track T", "remove the selected clip", "duplicate this clip"
    ]

    /// Use only unique visible roster names and unambiguous profile tags.
    /// Angle-bracket fallbacks deliberately invite replacement, never invented people.
    static func supportedRequests(library: ScriptLibrarySnapshot) -> [String] {
        let people = library.people.filter { !$0.hidden }
        let name = people.first { person in
            let key = normalized(person.name)
            return !key.isEmpty && people.filter { normalized($0.name) == key }.count == 1
        }?.name ?? "<person>"
        let tags = Set(library.tags)
        let tag = library.tags.first { tag in
            let key = normalized(tag)
            return !key.isEmpty && tags.filter { normalized($0) == key }.count == 1
        } ?? "<tag>"
        return ["remove clips with \(name)", "find scenes of \(name) \(tag)",
                "cut silence longer than 1 s on track 1", "add b-roll of \(tag) at 12 s",
                "set this clip speed to 1.5x", "captions off for this clip", "set music volume to 2",
                "set track 1 captions to bottom", "mute track 1",
                "remove clip 1 on track 1", "remove the selected clip", "duplicate this clip",
                "split this clip at 2 s", "trim this clip to 2 s", "mute this clip",
                "unmute this clip", "cover all areas", "remove clips tagged \(tag) on track 1",
                "make track 1 black and white", "apply sepia to this clip", "remove the look from track 1"]
    }

    /// "this clip", "the selected scene", "the current clip": the timeline selection.
    static let selectedClip = #"(?:this|the selected|the current|selected|the) (?:clip|scene|video)"#

    func parse(_ request: String, context: ParserContext) -> BuilderProgram {
        guard request.utf8.count <= 4096 else { return .unrecognised(["Request exceeds 4 KiB."]) }
        let text = Self.normalized(request)
        guard !text.isEmpty else { return .unrecognised(["Enter a request."]) }
        do {
            if let g = match(#"make (?:track|area) (i|ii|iii|iv|v|vi|[1-6]) black and white"#, text) {
                return .script([.init(.setTrackEffect(track: try track(g[0], context), effect: EffectSpec(preset: "bw")))])
            }
            if let g = match(#"remove the look from (?:(?:track|area) (i|ii|iii|iv|v|vi|[1-6])|(this clip))"#, text) {
                if !g[0].isEmpty { return .script([.init(.setTrackEffect(track: try track(g[0], context), effect: nil))]) }
                return .script([.init(.setClipEffect(clip: try selection(context).uid.uuidString, effect: nil))])
            }
            if let g = match(#"apply (.+) to (?:(?:track|area) (i|ii|iii|iv|v|vi|[1-6])|(this clip))"#, text) {
                guard let preset = EffectCatalog.presets.first(where: {
                    Self.normalized($0.id) == g[0] || Self.normalized($0.name) == g[0]
                        || ($0.id == "bw" && g[0] == "black and white")
                }) else { throw BuilderCommandFailure.invalid("Unknown look: \(g[0]).") }
                let effect = EffectSpec(preset: preset.id)
                if !g[1].isEmpty { return .script([.init(.setTrackEffect(track: try track(g[1], context), effect: effect))]) }
                return .script([.init(.setClipEffect(clip: try selection(context).uid.uuidString, effect: effect))])
            }
            if let g = match(#"remove (?:all )?(?:clips|scenes) with (.+)"#, text) {
                var filter = ClipFilter()
                filter.people = [try person(g[0], context)]
                return .script([.init(.removeClips(filter: filter))])
            }
            if let g = match(#"remove clips tagged (.+?)(?: on (?:track )?(i|ii|iii|iv|v|vi|[1-6]))?"#, text) {
                var filter = ClipFilter()
                filter.tags = [try tag(g[0], context)]
                if !g[1].isEmpty { filter.track = try track(g[1], context) }
                return .script([.init(.removeClips(filter: filter))])
            }
            for pattern in [#"find (?:me )?scenes (?:with|of|where|showing) (.+)"#,
                            #"search scenes for (.+)"#, #"show me (.+) scenes"#,
                            #"scenes with (.+)"#, #"find (.+)"#] {
                if let g = match(pattern, text) {
                    return BuilderSceneSearch.resolve(g[0], request: request, library: context.library)
                }
            }
            if let g = match(#"(?:cut|remove) silence(?: longer than ([0-9]+(?:\.[0-9]+)?)\s*s)? (on (?:track )?(?:i|ii|iii|iv|v|vi|[1-6])|in this clip)"#, text) {
                let threshold = g[0].isEmpty ? 0.3 : try seconds(g[0])
                guard threshold >= 0.05, threshold <= 60 else {
                    throw ScriptError.invalid("Silence threshold must be between 0.05 and 60 seconds.")
                }
                let clips: [TimelineClip]
                if g[1] == "in this clip" { clips = [try selection(context)] }
                else {
                    let index = try track(String(g[1].dropFirst(3)), context)
                    clips = context.document.videoTrack.filter { $0.track == index && !$0.bumper }
                }
                guard clips.count <= ScriptRunner.maximumSteps else {
                    throw ScriptError.invalid("Too many clips; narrow the request.")
                }
                var missing = Set<Int64>()
                for clip in clips {
                    guard !clip.bumper, clip.sourceStart != nil else {
                        throw ScriptError.invalid("Silence cuts require a non-bumper clip with source timing.")
                    }
                    let videoID = context.library.scenes.first { $0.id == clip.sceneID }?.videoID
                        ?? context.library.videos.first { $0.path == clip.videoFile }?.id
                    guard let videoID, context.library.videos.contains(where: { $0.id == videoID }) else {
                        throw ScriptError.invalid("Video is missing or outside this project.")
                    }
                    if !context.library.transcripts.contains(where: { $0.videoID == videoID && !$0.isTranslation }) {
                        missing.insert(videoID)
                    }
                }
                if !missing.isEmpty {
                    return .deferred(prerequisites: missing.sorted().map { .init(.ensureTranscript(video: $0)) })
                }
                return .script(try BuilderSilenceExpansion.steps(clips: clips, threshold: threshold, context: context))
            }
            if let g = match(#"add b-roll of (.+?) at (.+?)(?: on (?:track )?(i|ii|iii|iv|v|vi|[1-6]))?(?: for ([0-9]+(?:\.[0-9]+)?)\s*s)?"#, text) {
                var filter = SceneFilter()
                filter.tags = [try tag(g[0], context)]
                let at = try time(g[1], context)
                let lane = g[2].isEmpty ? try track(String(context.focusedTrack + 1), context) : try track(g[2], context)
                let duration = g[3].isEmpty ? nil : try seconds(g[3])
                let candidates = context.library.scenes.filter { filter.matches($0) }.sorted { $0.id < $1.id }
                guard let scene = candidates.first else { throw ScriptError.invalid("No available scene matches that tag.") }
                // One insertion, deterministic lowest scene ID; the preview identifies it.
                return .script([.init(.addCutaway(scene: scene.id, at: at, track: lane,
                                                  duration: duration, coverAll: false))])
            }
            if let g = match(#"remove clip ([1-9][0-9]*) on track (i|ii|iii|iv|v|vi|[1-6])"#, text) {
                let lane = try track(g[1], context)
                // Visible video clips, including B-roll, in timeline order.
                let clips = context.document.videoTrack.enumerated().filter { $0.element.track == lane && !$0.element.bumper }
                    .sorted { lhs, rhs in
                        lhs.element.startTime == rhs.element.startTime
                            ? lhs.offset < rhs.offset : lhs.element.startTime < rhs.element.startTime
                    }
                guard let ordinal = Int(g[0]), ordinal <= clips.count else {
                    throw ScriptError.invalid("That clip number is not on this track.")
                }
                return .script([.init(.removeClip(clip: clips[ordinal - 1].element.uid.uuidString))])
            }
            if match(#"(?:remove|delete) \#(Self.selectedClip)"#, text) != nil {
                return .script([.init(.removeClip(clip: try selection(context).uid.uuidString))])
            }
            if let g = match(#"(?:remove|delete) (?:this|the selected|the current|selected|the) (sound|music|text|image|overlay|crop block)"#, text) {
                return .script([.init(try removeSelectedElement(g[0], context))])
            }
            if let g = match(#"set this clip speed to ([0-9]+(?:\.[0-9]+)?)\s*x"#, text) {
                let speed = try seconds(g[0])
                let command = BuilderCommand.setClipSpeed(clip: try selection(context).uid.uuidString, speed: speed)
                try command.validateExpansion()
                return .script([.init(command)])
            }
            if text == "captions off for this clip" {
                return .script([.init(.setClipCaptions(clip: try selection(context).uid.uuidString, captions: "none"))])
            }
            if let g = match(#"set music volume to ([1-5])"#, text) {
                guard context.document.soundTrack.count == 1, let sound = context.document.soundTrack.first,
                      let volume = Int(g[0]) else {
                    throw ScriptError.invalid("Music volume requires exactly one sound block.")
                }
                return .script([.init(.setSoundVolume(sound: sound.uid.uuidString, volume: volume))])
            }
            if let g = match(#"set track (i|ii|iii|iv|v|vi|[1-6]) captions to (none|top|middle|bottom)"#, text) {
                return .script([.init(.setTrackCaptions(track: try track(g[0], context), captions: g[1]))])
            }
            if let g = match(#"(mute|unmute) track (i|ii|iii|iv|v|vi|[1-6])"#, text) {
                return .script([.init(.setTrackMuted(track: try track(g[1], context), muted: g[0] == "mute"))])
            }
            if match(#"duplicate \#(Self.selectedClip)"#, text) != nil {
                return .script([.init(.duplicateClip(clip: try selection(context).uid.uuidString))])
            }
            // "split the selected scene in 4 separate ones", "split this clip into 6 equal parts".
            if let g = match(#"split \#(Self.selectedClip) (?:in|into) ([0-9]+)(?: (?:equal|separate|different|new|even|smaller))*(?: (?:parts|pieces|scenes|clips|ones|segments|sections))?(?: of (?:equal|the same) (?:size|sizes|length|lengths|duration|durations))?"#, text) {
                guard let parts = Int(g[0]), (2...12).contains(parts) else {
                    throw ScriptError.invalid("Parts must be between 2 and 12.")
                }
                return .script([.init(.splitClipEvenly(clip: try selection(context).uid.uuidString, parts: parts))])
            }
            if let g = match(#"split \#(Self.selectedClip) at (.+)"#, text) {
                return .script([.init(.splitClip(clip: try selection(context).uid.uuidString,
                                                at: try time(g[0], context)))])
            }
            if let g = match(#"trim \#(Self.selectedClip) to ([0-9]+(?:\.[0-9]+)?)\s*s"#, text) {
                return .script([.init(.trimClip(clip: try selection(context).uid.uuidString,
                                               duration: try seconds(g[0])))])
            }
            if let g = match(#"(mute|unmute) \#(Self.selectedClip)"#, text) {
                return .script([.init(.setClipMuted(clip: try selection(context).uid.uuidString,
                                                   muted: g[0] == "mute"))])
            }
            if text == "cover all areas" {
                return .script([.init(.setCutawayCoverAll(clip: try selection(context).uid.uuidString, coverAll: true))])
            }
            return .unrecognised(["The entire request must match a supported shape. Unknown actions, qualifiers, negation, or extra instructions cannot be ignored."])
        } catch { return .unrecognised([error.localizedDescription]) }
    }

    nonisolated static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: "\\A(?:" + pattern + ")\\z"),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<result.numberOfRanges).map {
            Range(result.range(at: $0), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private func person(_ value: String, _ context: ParserContext) throws -> String {
        let matches = context.library.people.filter { !$0.hidden && Self.normalized($0.name) == value }
        guard matches.count == 1, let found = matches.first else {
            throw ScriptError.invalid(matches.isEmpty ? "Unknown person or unconsumed words: \(value)."
                                      : "Ambiguous person name: \(value). Use a unique roster name.")
        }
        return found.key
    }

    private func tag(_ value: String, _ context: ParserContext) throws -> String {
        let matches = Set(context.library.tags.filter { Self.normalized($0) == value })
        guard matches.count == 1, let found = matches.first else {
            throw ScriptError.invalid("Unknown or ambiguous profile tag, or unconsumed words: \(value).")
        }
        return found
    }

    private func track(_ value: String, _ context: ParserContext) throws -> Int {
        let value = value.hasPrefix("track ") ? String(value.dropFirst(6)) : value
        let roman = ["i", "ii", "iii", "iv", "v", "vi"]
        guard let index = roman.firstIndex(of: value) ?? Int(value).map({ $0 - 1 }),
              (0..<TimelineDocument.maxTracks).contains(index) else {
            throw ScriptError.invalid("Use a visible track number, such as Track I/1 or Track II/2.")
        }
        guard index < context.document.trackCount else { throw ScriptError.invalid("That track is not visible.") }
        return index
    }

    private func seconds(_ text: String) throws -> Double {
        guard let value = Double(text), value.isFinite, value > 0, value <= 86400 else {
            throw ScriptError.invalid("Duration must be positive and at most one day.")
        }
        return value
    }

    private func time(_ text: String, _ context: ParserContext) throws -> Double {
        // The grammar's 'at' also accepts the natural 'at the playhead'.
        if text == "the playhead" || text == "at the playhead" { return context.playhead }
        if let g = match(#"([0-9]+):([0-5][0-9])"#, text), let minutes = Double(g[0]), let seconds = Double(g[1]) {
            let result = minutes * 60 + seconds
            if result <= 86400 { return result }
        }
        if let g = match(#"([0-9]+(?:\.[0-9]+)?)\s*s"#, text), let result = Double(g[0]), result <= 86400 { return result }
        throw ScriptError.invalid("Use a timeline time such as 0:12, 12s, or at the playhead; extra words are not supported.")
    }

    /// Remove whatever non-clip element is selected, when it matches the kind named.
    private func removeSelectedElement(_ kind: String, _ context: ParserContext) throws -> BuilderCommand {
        let wanted: Set<String> = kind == "music" ? ["sound"] : kind == "crop block" ? ["crop"] : [kind]
        guard let selection = context.selection, wanted.contains(selection.kind) else {
            throw ScriptError.invalid("Select the \(kind) in the timeline first.")
        }
        switch selection {
        case .sound(let id): return .removeSound(sound: id.uuidString)
        case .text(let id), .image(let id), .overlay(let id): return .removeOverlay(overlay: id.uuidString)
        case .crop(let id): return .removeCropBlock(block: id.uuidString)
        case .clip(let id): return .removeClip(clip: id.uuidString)
        }
    }

    private func selection(_ context: ParserContext) throws -> TimelineClip {
        guard let id = context.selectedClipID, let clip = context.document.videoTrack.first(where: { $0.uid == id }) else {
            throw ScriptError.invalid("Select a clip in the timeline before using ‘this clip’ or ‘cover all areas’.")
        }
        return clip
    }
}
