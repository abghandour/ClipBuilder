import Foundation

nonisolated enum TimelineSlowRules {
    struct Result: Sendable {
        var document: TimelineDocument
        var groups: [UUID]
        var skipped: Int
        var count: Int { groups.count }
    }

    /// Contacts use the timeline clock, before this edit. The owner track is
    /// first because its source speed defines the lead on the shared clock.
    static func insert(_ contacts: [Double], owner: UUID, strength: StrikeImpactRules.Strength,
                       into document: TimelineDocument) -> Result? {
        let clipOwners = Dictionary(document.videoTrack.map { ($0.uid, $0.uid) }, uniquingKeysWith: { first, _ in first })
        guard clipOwners.count == document.videoTrack.count,
              let ownerClip = document.videoTrack.first(where: { $0.uid == owner }),
              ownerClip.hold != true, !ownerClip.bumper, !ownerClip.isCutaway else { return nil }
        let grouped = Dictionary(grouping: document.videoTrack, by: \.track)
        let order = [ownerClip.track] + grouped.keys.filter { $0 != ownerClip.track }.sorted()
        let tracks = order.map { (grouped[$0] ?? []).sorted { $0.startTime < $1.startTime } }
        let candidates = contacts.filter { $0 > ownerClip.startTime && $0 <= ownerClip.startTime + ownerClip.duration }
        let existing = (document.slowMotion?.groups ?? []).flatMap { group in
            group.id.flatMap { currentIntervals(group: $0, in: document) } ?? []
        }
        let eligible = candidates.filter { time in
            let lower = max(ownerClip.startTime, time - strength.lead / ownerClip.effectiveSpeed)
            return !existing.contains {
                lower < $0.end - 1e-9
                    && time > $0.start + 1e-9
            }
        }
        guard let slowed = StrikeImpactRules.sharedSlowing(tracks, contacts: eligible, strength: strength),
              !slowed.stretches.isEmpty else { return nil }
        var result = document
        var state = document.slowMotion ?? TimelineSlowState()
        state.preserveChanges(in: document)
        if state.originals == nil {
            state.originals = TimelineSlowState.saved(document.videoTrack)
            state.resolved = TimelineSlowState.saved(document.videoTrack)
            state.lanes = .init(document)
        }
        var owners = state.owners ?? clipOwners
        let inverse = StrikeImpactRules.inverse(state.stretches)
        let groups = slowed.stretches.map { stretch in
            TimelineSlowState.Group(id: UUID(), stretch: .init(
                start: StrikeImpactRules.mapped(stretch.start, through: inverse),
                end: StrikeImpactRules.mapped(stretch.end, through: inverse), factor: stretch.factor), strength: strength)
        }
        var pieces = slowed.tracks.flatMap { $0 }
        var sourceByPiece: [UUID: UUID] = [:]
        for index in pieces.indices {
            let piece = pieces[index]
            guard let original = document.videoTrack.first(where: { $0.uid == piece.uid })
                ?? document.videoTrack.first(where: {
                $0.track == piece.track && $0.videoFile == piece.videoFile
                    && piece.startTime >= StrikeImpactRules.mapped($0.startTime, through: slowed.stretches) - 1e-9
                    && piece.startTime < StrikeImpactRules.mapped($0.startTime + $0.duration, through: slowed.stretches) - 1e-9
            }) else { continue }
            sourceByPiece[piece.uid] = original.uid
            owners[piece.uid] = owners[original.uid] ?? original.uid
            // The splitter marks affected pieces. Unrelated clips only move;
            // they must not acquire provenance that removal has to undo.
            if piece.slowLineage != nil { pieces[index].slowLineage = owners[piece.uid] }
            if let window = slowed.stretches.firstIndex(where: {
                piece.startTime >= StrikeImpactRules.mapped($0.start, through: slowed.stretches) - 1e-9
                    && piece.startTime + piece.duration <= StrikeImpactRules.mapped($0.end, through: slowed.stretches) + 1e-9
            }) {
                pieces[index].slowGroup = groups[window].id
            }
        }
        // Keep the document's ordering, including interleaved tracks.
        result.videoTrack = document.videoTrack.flatMap { original in
            pieces.filter { sourceByPiece[$0.uid] == original.uid }
        }
        TimelineLaneMapping.stretches(slowed.stretches).apply(to: &result)
        state.groups = (state.groups ?? []) + groups
        state.owners = owners
        state.applied = TimelineSlowState.saved(result.videoTrack)
        state.appliedLanes = .init(result)
        result.slowMotion = state
        return Result(document: result, groups: groups.compactMap(\.id), skipped: slowed.skipped + candidates.count - eligible.count)
    }

    static func strength(group: UUID, in document: TimelineDocument) -> StrikeImpactRules.Strength? {
        document.slowMotion?.groups?.first { $0.id == group }?.strength
    }

    /// Current screen intervals, joined across user cuts but never across
    /// pauses. Each track must cover the same motion, with source continuity
    /// across its cuts/holds; a trim, move or unrelated gap rejects removal.
    static func currentIntervals(group: UUID, in document: TimelineDocument) -> [StrikeImpactRules.Stretch]? {
        let members = document.videoTrack.filter { $0.slowGroup == group && $0.hold != true }
        guard !members.isEmpty else { return nil }
        var reference: [StrikeImpactRules.Stretch]?
        for track in Set(members.map(\.track)).sorted() {
            let pieces = members.filter { $0.track == track }.sorted { $0.startTime < $1.startTime }
            var intervals: [StrikeImpactRules.Stretch] = []
            var previous: TimelineClip?
            for piece in pieces {
                guard piece.duration > 0, piece.duration.isFinite, piece.startTime.isFinite else { return nil }
                if let previous {
                    guard previous.videoFile == piece.videoFile, previous.sceneID == piece.sceneID,
                          abs((previous.sourceStart ?? 0) + previous.sourceSpan - (piece.sourceStart ?? 0)) < 1e-8 else { return nil }
                    let end = previous.startTime + previous.duration
                    guard piece.startTime >= end - 1e-8 else { return nil }
                    if piece.startTime > end + 1e-8 {
                        let holds = document.videoTrack.filter {
                            $0.track == track && $0.hold == true && $0.startTime >= end - 1e-8
                                && $0.startTime + $0.duration <= piece.startTime + 1e-8
                        }.sorted { $0.startTime < $1.startTime }
                        var cursor = end
                        for hold in holds {
                            guard abs(hold.startTime - cursor) < 1e-8,
                                  hold.videoFile == piece.videoFile, hold.sceneID == piece.sceneID,
                                  abs((hold.sourceStart ?? 0) - (piece.sourceStart ?? 0)) < 1e-8 else { return nil }
                            cursor += hold.duration
                        }
                        guard abs(cursor - piece.startTime) < 1e-8 else { return nil }
                    }
                }
                if let last = intervals.last, abs(last.end - piece.startTime) < 1e-8 {
                    intervals[intervals.count - 1].end = piece.startTime + piece.duration
                } else {
                    intervals.append(.init(start: piece.startTime, end: piece.startTime + piece.duration, factor: 1))
                }
                previous = piece
            }
            if let reference {
                guard reference.count == intervals.count, zip(reference, intervals).allSatisfy({
                    abs($0.start - $1.start) < 1e-8 && abs($0.end - $1.end) < 1e-8
                }) else { return nil }
            } else { reference = intervals }
        }
        return reference
    }

    static func removed(group: UUID, in document: TimelineDocument) -> TimelineDocument? {
        guard Set(document.videoTrack.map(\.uid)).count == document.videoTrack.count,
              var state = document.slowMotion,
              let record = state.groups?.first(where: { $0.id == group }), let stretch = record.stretch else { return nil }
        state.preserveChanges(in: document)
        guard let intervals = currentIntervals(group: group, in: document), !intervals.isEmpty else { return nil }
        let inverse = intervals.map {
            StrikeImpactRules.Stretch(start: $0.start, end: $0.end, factor: 1 / stretch.factor)
        }
        state.groups?.removeAll { $0.id == group }
        let remaining = state.stretches
        let owners = state.owners ?? [:]
        let applied = TimelineSlowState.clips(state.applied)
        let originals = TimelineSlowState.clips(state.originals)
        var result = document
        result.videoTrack = document.videoTrack.map { clip in
            var clip = clip
            clip.startTime = StrikeImpactRules.mapped(clip.startTime, through: inverse)
            if clip.slowGroup == group {
                if clip.hold != true {
                    clip.speed = clip.effectiveSpeed / stretch.factor
                    clip.duration *= stretch.factor
                }
                clip.slowGroup = nil
            }
            return clip
        }
        // Only this edit's untouched lineages can recover their unsplit source.
        // Other clips keep their current values and only move in time above.
        let roots = Set(document.videoTrack.filter { $0.slowGroup == group }.map { owners[$0.uid] ?? $0.uid })
        for original in originals where roots.contains(original.uid) && !(state.editedRoots ?? []).contains(original.uid) {
            let indices = document.videoTrack.indices.filter { (owners[document.videoTrack[$0].uid] ?? document.videoTrack[$0].uid) == original.uid }
            guard !indices.isEmpty, indices.allSatisfy({ index in
                guard let expected = applied.first(where: { $0.uid == document.videoTrack[index].uid }) else { return false }
                return TimelineSlowState.matchesSavedClip(document.videoTrack[index], expected)
            }) else { continue }
            let old = indices.map { document.videoTrack[$0] }
            let windows = remaining.filter { $0.start < original.startTime + original.duration - 1e-9 && $0.end > original.startTime + 1e-9 }
            var rebuilt: [TimelineClip]
            if windows.isEmpty {
                var moved = original
                moved.startTime = StrikeImpactRules.mapped(original.startTime, through: remaining)
                moved.slowLineage = remaining.isEmpty ? original.slowLineage : original.uid
                rebuilt = [moved]
            } else {
                let resolved = TimelineSlowState.clips(state.resolved).first { $0.uid == original.uid } ?? original
                rebuilt = StrikeImpactRules.applying(remaining, to: [[resolved]])[0]
                for i in rebuilt.indices {
                    rebuilt[i].slowLineage = original.uid
                    let matching = old.first { abs(($0.sourceStart ?? 0) - (rebuilt[i].sourceStart ?? 0)) < 1e-9 }
                    if let matching { rebuilt[i].uid = matching.uid }
                    rebuilt[i].slowGroup = state.groups?.first {
                        guard let window = $0.stretch else { return false }
                        return rebuilt[i].startTime >= StrikeImpactRules.mapped(window.start, through: remaining) - 1e-9
                            && rebuilt[i].startTime + rebuilt[i].duration <= StrikeImpactRules.mapped(window.end, through: remaining) + 1e-9
                    }?.id
                }
            }
            let ids = Set(old.map(\.uid))
            guard let position = result.videoTrack.firstIndex(where: { ids.contains($0.uid) }) else { continue }
            result.videoTrack.removeAll { ids.contains($0.uid) }
            result.videoTrack.insert(contentsOf: rebuilt, at: position)
            for clip in rebuilt { state.owners?[clip.uid] = original.uid }
        }
        let currentLanes = TimelineSlowState.Lanes(document)
        TimelineLaneMapping.stretches(inverse).apply(to: &result)
        if remaining.isEmpty {
            // Edited lineages can retain automatic boundaries beside a user
            // cut. Keep their provenance so removing slow motion does not end
            // a stay there; rebuilt originals already recovered their own value.
            if let original = state.lanes, let expected = state.appliedLanes {
                original.restoreUnedited(in: &result, current: currentLanes, expected: expected)
            }
            result.slowMotion = nil
        } else {
            state.applied = TimelineSlowState.saved(result.videoTrack)
            state.appliedLanes = .init(result)
            result.slowMotion = state
        }
        return result
    }
}
