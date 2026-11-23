import Foundation

/// Merge on the main source clock without changing a saved drawing's clock.
nonisolated enum WizardSharedPauses {
    static func showsSeveralPictures(_ clip: WizardPlanClip, cut: TimelineDocument) -> Bool {
        !clip.areaClips.isEmpty || cut.videoTrack.count > 1 || cut.videoTrack.contains {
            if let plan = $0.framingPlan, case .composed = plan { return true }
            return false
        }
    }

    struct Source: Sendable {
        var scene: SceneRecord
        var start: Double
        var end: Double
        var companion: Bool
    }

    static func sources(_ clip: WizardPlanClip, sceneMap: [Int64: SceneRecord]) -> [Source] {
        var result: [Source] = []
        if let scene = sceneMap[clip.sceneID] {
            result.append(Source(scene: scene, start: clip.start, end: clip.end, companion: false))
        }
        for area in clip.areaClips {
            guard let scene = sceneMap[area.sceneID] else { continue }
            result.append(Source(scene: scene, start: area.start,
                end: min(area.end, area.start + clip.end - clip.start), companion: true))
        }
        return result
    }

    struct Candidates {
        var contacts: [Double] = []
        var drawings: [Telestration] = []
        var originals: [(drawing: Telestration, source: String?)] = []
        var useContacts = false

        func timing(for clip: WizardPlanClip, seconds: Double?) -> WizardStrikePauses.Timing {
            var result = WizardStrikePauses.timing(for: clip, contacts: contacts,
                seconds: useContacts ? seconds : nil, drawings: drawings)
            for index in result.pauses.indices {
                guard let drawing = result.pauses[index].drawing,
                      let candidate = drawings.firstIndex(where: { TelestrationMotionRules.paused($0) == drawing }) else { continue }
                result.pauses[index].drawing = TelestrationMotionRules.paused(originals[candidate].drawing)
                result.pauses[index].source = originals[candidate].source
            }
            return result
        }

        /// The pauses every picture can take. A drawing dropped at another
        /// picture's edge gives back the contact it had replaced, so the
        /// choice is made again without it until nothing more is dropped.
        func resolved(for clip: WizardPlanClip, seconds: Double?, tracks: [[TimelineClip]]?) -> WizardStrikePauses.Timing {
            guard let tracks else { return timing(for: clip, seconds: seconds) }
            if drawings.contains(where: { $0.motion != nil }) {
                var paused = self
                paused.drawings = drawings.map(TelestrationMotionRules.paused)
                paused.originals = originals.map { (TelestrationMotionRules.paused($0.drawing), $0.source) }
                var result = paused.resolved(for: clip, seconds: seconds, tracks: tracks)
                if result.pauses.contains(where: { pause in
                    originals.contains { $0.drawing.motion != nil && TelestrationMotionRules.paused($0.drawing) == pause.drawing }
                }) { result.motionFallbackReasons = [TelestrationMotionRules.severalPictures] }
                return result
            }
            var remaining = self
            var dropped = 0
            while true {
                // On the mapped clock each candidate is its own drawing, so a
                // drawing that two pictures reach at different moments is two.
                let raw = WizardStrikePauses.timing(for: clip, contacts: remaining.contacts,
                    seconds: remaining.useContacts ? seconds : nil, drawings: remaining.drawings)
                let kept = Set(StrikeFreezeRules.sharedPauseIndices(tracks, pauses: WizardSharedPauses.pauses(raw)))
                // Also lost: a drawing no picture shows at its moment (its
                // companion was left out while another shows the same file).
                // Holding for it would freeze the reel with nothing drawn.
                let mainSource = tracks.flatMap { $0 }.first { $0.track == 0 }?.videoFile
                let lost = Set(raw.pauses.indices.compactMap { index -> Int? in
                    guard let mapped = raw.pauses[index].drawing,
                          let candidate = remaining.drawings.firstIndex(of: mapped) else { return nil }
                    guard kept.contains(index) else { return candidate }
                    let original = remaining.originals[candidate]
                    let time = raw.pauses[index].time
                    let shown = tracks.flatMap { $0 }.contains { clip in
                        guard clip.videoFile == (original.source ?? mainSource), let start = clip.sourceStart,
                              time >= clip.startTime, time < clip.startTime + clip.duration else { return false }
                        return abs(start + (time - clip.startTime) * clip.effectiveSpeed - original.drawing.time) <= 1.0 / 30 + 1e-9
                    }
                    return shown ? nil : candidate
                })
                guard !lost.isEmpty else {
                    var result = WizardSharedPauses.filtered(remaining.timing(for: clip, seconds: seconds), tracks: tracks)
                    result.filteredDrawings += dropped
                    return result
                }
                dropped += lost.count
                for index in lost.sorted(by: >) {
                    remaining.drawings.remove(at: index)
                    remaining.originals.remove(at: index)
                }
            }
        }
    }

    /// `visible`: the video files the extracted cut really shows. A companion
    /// the framing left out never pauses the picture that is on screen.
    static func candidates(_ clip: WizardPlanClip, sceneMap: [Int64: SceneRecord],
                           sourceTypes: [Int64: VideoType], contacts: [String: [Double]],
                           drawings: [String: [Telestration]], options: WizardOptions,
                           visible: Set<String>? = nil) -> Candidates {
        var result = Candidates()
        var seenContacts = Set<String>(), seenDrawings = Set<String>()
        for source in sources(clip, sceneMap: sceneMap) {
            let path = source.scene.videoPath
            if source.companion, let visible, !visible.contains((path as NSString).standardizingPath) { continue }
            let offset = clip.start - source.start
            if WizardStrikePauses.contactsRequested(options), sourceTypes[source.scene.videoID] == .fight {
                result.useContacts = true
                // The same footage shown twice at the same moment is one event.
                // Against earlier pictures only: within one source the list is
                // passed on as saved, repeats included, as it always was.
                let own = (contacts[path] ?? []).filter { $0 >= source.start && $0 <= source.end }
                result.contacts += own.filter { !seenContacts.contains("\(path)|\($0)|\(offset)") }.map { $0 + offset }
                for contact in own { seenContacts.insert("\(path)|\(contact)|\(offset)") }
            }
            for drawing in drawings[path] ?? [] where drawing.time >= source.start && drawing.time <= source.end {
                guard !seenDrawings.contains("\(path)|\(drawing.time)|\(offset)") else { continue }
                var mapped = drawing
                mapped.time += offset
                result.drawings.append(mapped)
                result.originals.append((drawing, source.companion ? path : nil))
            }
            for drawing in drawings[path] ?? [] where drawing.time >= source.start && drawing.time <= source.end {
                seenDrawings.insert("\(path)|\(drawing.time)|\(offset)")
            }
        }
        return result
    }

    /// The companion footage a cut really shows, for `candidates(visible:)`.
    /// A clip's file is its scene's, as the renderer resolves it. A companion
    /// cut from the main clip's own file counts only when it has a picture of
    /// its own (a track above the main one): the main picture is not it.
    static func visibleSources(_ cut: TimelineDocument, sceneMap: [Int64: SceneRecord], main: String) -> Set<String> {
        let main = (main as NSString).standardizingPath
        var result = Set<String>()
        for clip in cut.videoTrack {
            guard let raw = clip.sceneID.flatMap({ sceneMap[$0]?.videoPath }) ?? clip.videoFile else { continue }
            let path = (raw as NSString).standardizingPath
            if clip.track != 0 || path != main { result.insert(path) }
        }
        return result
    }

    /// The shortest stretch at each end of a split cut that every picture
    /// plays whole: what a transition into or out of the cut can overlap.
    static func edgeSegments(_ pieces: [TimelineClip]) -> (head: Double, tail: Double)? {
        let bounds = Set(pieces.flatMap { [$0.startTime, $0.startTime + $0.duration] }.map { ($0 * 1000).rounded() / 1000 }).sorted()
        // The renderer drops a stretch under 0.05 s; it is not a segment here either.
        let lengths = zip(bounds, bounds.dropFirst()).map { $1 - $0 }.filter { $0 >= 0.05 - 1e-9 }
        guard let head = lengths.first, let tail = lengths.last else { return nil }
        return (head, tail)
    }

    static func tracks(_ cut: TimelineDocument) -> [[TimelineClip]] {
        let grouped = Dictionary(grouping: cut.videoTrack, by: \.track)
        return grouped.keys.sorted().map { grouped[$0] ?? [] }
    }

    /// Ordinary composed cuts may still carry their declarative area plan.
    /// Materialize it before checking boundaries, just as reel assembly does.
    static func expanded(_ cut: TimelineDocument) -> TimelineDocument {
        guard cut.videoTrack.count == 1, let main = cut.videoTrack.first,
              let plan = main.framingPlan, case .composed(let layout, let areas, _) = plan else { return cut }
        var result = cut
        var clips: [TimelineClip] = []
        for (track, area) in layout.areas.enumerated() where track < TimelineDocument.maxTracks {
            for segment in areas where segment.areaID == area.id {
                var piece = main
                piece.uid = UUID()
                piece.sceneID = segment.sourcePath == main.videoFile ? main.sceneID : nil
                piece.videoFile = segment.sourcePath
                piece.track = track
                piece.sourceStart = segment.start
                piece.sourceEnd = segment.start + segment.duration
                piece.startTime = main.startTime + (segment.timelineStart ?? 0) / main.effectiveSpeed
                piece.duration = segment.duration / main.effectiveSpeed
                piece.muted = track > 0 || main.muted
                piece.cameraPath = nil
                piece.cropXFrac = nil
                piece.centerStage = false
                piece.areaRegion = segment.region
                piece.areaFocus = segment.focus
                if case .static(let window) = segment.framing { piece.areaWindow = window ?? FreeCropRect() }
                if track == 0, let path = main.videoFile, let start = main.sourceStart {
                    piece.framingProgramAudio = .init(path: path,
                        start: start + (segment.timelineStart ?? 0), visualStart: segment.start)
                }
                clips.append(piece)
            }
            result.trackCount = max(result.trackCount, track + 1)
            result.trackSequential[track] = false
        }
        guard !clips.isEmpty else { return cut }
        result.videoTrack = clips
        return result
    }

    static func pauses(_ timing: WizardStrikePauses.Timing, mainSource: String? = nil) -> [StrikeFreezeRules.Pause] {
        timing.pauses.map {
            .init(time: $0.time, duration: $0.duration, drawing: $0.drawing, source: $0.source ?? mainSource)
        }
    }

    static func filtered(_ timing: WizardStrikePauses.Timing, tracks: [[TimelineClip]]) -> WizardStrikePauses.Timing {
        let kept = Set(StrikeFreezeRules.sharedPauseIndices(tracks, pauses: pauses(timing)))
        var result = timing
        result.pauses = []
        for (index, pause) in timing.pauses.enumerated() {
            if kept.contains(index) { result.pauses.append(pause) }
            else if pause.drawing != nil { result.filteredDrawings += 1 }
            else { result.filteredContacts += 1 }
        }
        return result
    }
}
