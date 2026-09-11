import Foundation

/// Closed, anchored grammar. No stop-word stripping, fuzzy entities, residual
/// word allowance, model calls, or prerequisite service work.
@MainActor
struct BuilderRequestParser {
    static let supportedRequests = [
        "remove (all) clips/scenes with <person>",
        "remove clips tagged <tag> [on track N]",
        "find <person> <tag> / find scenes of <person> <tag>",
        "cut/remove silence [longer than N s] on track N / in this clip",
        "add b-roll of <tag> at <time> [on track N] [for N s]",
        "split this clip at <time>", "trim this clip to N s",
        "mute/unmute this clip", "cover all areas"
    ]

    func parse(_ request: String, context: ParserContext) -> BuilderProgram {
        guard request.utf8.count <= 4096 else { return .unrecognised(["Request exceeds 4 KiB."]) }
        let text = Self.normalized(request)
        guard !text.isEmpty else { return .unrecognised(["Enter a request."]) }
        do {
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
            if let g = match(#"find (?:scenes of )?(.+)"#, text) {
                return .find(try findFilter(g[0], context), presentation: request)
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
            if let g = match(#"split this clip at (.+)"#, text) {
                return .script([.init(.splitClip(clip: try selection(context).uid.uuidString,
                                                at: try time(g[0], context)))])
            }
            if let g = match(#"trim this clip to ([0-9]+(?:\.[0-9]+)?)\s*s"#, text) {
                return .script([.init(.trimClip(clip: try selection(context).uid.uuidString,
                                               duration: try seconds(g[0])))])
            }
            if text == "mute this clip" || text == "unmute this clip" {
                return .script([.init(.setClipMuted(clip: try selection(context).uid.uuidString,
                                                   muted: text == "mute this clip"))])
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

    private func findFilter(_ value: String, _ context: ParserContext) throws -> SceneFilter {
        var candidates: [SceneFilter] = []
        if let resolved = try? tag(value, context) {
            var filter = SceneFilter(); filter.tags = [resolved]; candidates.append(filter)
        }
        for name in Set(context.library.people.filter { !$0.hidden }.map { Self.normalized($0.name) }) {
            guard value == name || value.hasPrefix(name + " ") else { continue }
            let key = try person(name, context)
            let rest = value == name ? "" : String(value.dropFirst(name.count + 1))
            var filter = SceneFilter(); filter.people = [key]
            if !rest.isEmpty {
                guard let resolved = try? tag(rest, context) else { continue }
                filter.tags = [resolved]
            }
            candidates.append(filter)
        }
        guard candidates.count == 1, let filter = candidates.first else {
            throw ScriptError.invalid("Find needs an unambiguous roster name and/or profile tag with no extra words.")
        }
        return filter
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

    private func selection(_ context: ParserContext) throws -> TimelineClip {
        guard let id = context.selectedClipID, let clip = context.document.videoTrack.first(where: { $0.uid == id }) else {
            throw ScriptError.invalid("Select a clip in the timeline before using ‘this clip’ or ‘cover all areas’.")
        }
        return clip
    }
}
