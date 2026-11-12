import Foundation

/// One item of the Express reel (docs/Express-Reel-List-Plan.md): something
/// the user selected in a Footage section, in reel order, with a snapshot of
/// its range so the list can draw it while that section is not loaded.
nonisolated struct MiniReelItem: Sendable, Equatable, Hashable {
    var kind: MiniWizardFlow.FootageKind
    /// Q&A: the exchange's scene id; Transcript and Fight: the pick id;
    /// Highlights: the candidate's selection id.
    var itemID: Int64
    var position = 0
    var sceneID: Int64?
    var start: Double
    var end: Double
    var title: String

    var range: ClosedRange<Double> { start...max(start, end) }
    /// The preview clip id (the first cut, for a Highlights candidate).
    var clipID: String { MiniReelRules.clipID(kind: kind, itemID: itemID) }
    var key: MiniReelRules.Key { .init(kind: kind, itemID: itemID) }
}

/// Pure rules for the reel.
nonisolated enum MiniReelRules {
    struct Key: Hashable, Sendable {
        var kind: MiniWizardFlow.FootageKind
        var itemID: Int64
    }

    static func clipID(kind: MiniWizardFlow.FootageKind, itemID: Int64) -> String {
        switch kind {
        case .qa: "qa-\(itemID)"
        case .transcript: "pick-\(itemID)"
        case .fightMetrics: "fight-\(itemID)"
        case .highlights: "take-\(itemID)-0"
        }
    }

    /// The reel item a preview clip id belongs to.
    static func key(of clipID: String) -> Key? {
        guard let owner = WizardPreviewRows.owner(of: clipID) else { return nil }
        return switch owner {
        case .qa(let id): Key(kind: .qa, itemID: id)
        case .transcriptPick(let id): Key(kind: .transcript, itemID: id)
        case .fightPick(let id): Key(kind: .fightMetrics, itemID: id)
        case .take(let id): Key(kind: .highlights, itemID: id)
        }
    }

    static func item(_ items: [MiniReelItem], clipID: String) -> MiniReelItem? {
        guard let key = key(of: clipID) else { return nil }
        return items.first { $0.key == key }
    }

    /// The sections the reel draws from, in order of first appearance.
    static func kinds(_ items: [MiniReelItem]) -> [MiniWizardFlow.FootageKind] {
        var seen = Set<MiniWizardFlow.FootageKind>()
        return items.compactMap { seen.insert($0.kind).inserted ? $0.kind : nil }
    }

    /// What a loaded section keeps right now, in its own order, as reel
    /// items with fresh snapshots.
    static func kept(run: MiniWizardRun) -> [MiniReelItem] {
        switch run.footageKind {
        case .qa:
            guard let qa = run.qa else { return [] }
            return MiniWizardQARules.ordering(qa.sections, by: qa.keptOrder)
                .filter { qa.kept.contains($0.id) && $0.scene.videoID == run.video.id && $0.range.upperBound > $0.range.lowerBound }
                .map { MiniReelItem(kind: .qa, itemID: $0.id, sceneID: $0.scene.id,
                                    start: $0.range.lowerBound, end: $0.range.upperBound, title: $0.question) }
        case .transcript:
            return (run.transcript?.picks ?? []).filter(\.kept).enumerated().map { index, pick in
                MiniReelItem(kind: .transcript, itemID: pick.id, sceneID: pick.sceneID,
                             start: pick.start, end: pick.end, title: "Passage \(index + 1)")
            }
        case .fightMetrics:
            return (run.fight?.picks ?? []).map {
                MiniReelItem(kind: .fightMetrics, itemID: $0.id, sceneID: $0.sceneID,
                             start: $0.start, end: $0.end, title: "Stretch \($0.position + 1)")
            }
        case .highlights:
            return run.candidates.compactMap { candidate in
                guard candidate.kept, let first = candidate.take.plan.clips.first(where: { $0.end > $0.start }) else { return nil }
                return MiniReelItem(kind: .highlights, itemID: candidate.id, sceneID: first.sceneID,
                                    start: first.start, end: first.end, title: candidate.selection.name)
            }
        }
    }

    /// `items` with its `kind` rows brought in line with `kept`: rows whose
    /// item is no longer kept go, kept items without a row join at the end in
    /// the section's order, and the rest take the live snapshot.
    /// `known` lists every item id the loaded run can speak for (Highlights:
    /// its batch's candidates, kept or not); an item of the kind outside it
    /// belongs to another batch and is left as it is. Nil: the run owns them all.
    static func reconcile(_ items: [MiniReelItem], kind: MiniWizardFlow.FootageKind, kept: [MiniReelItem],
                          known: Set<Int64>? = nil) -> [MiniReelItem] {
        let live = Dictionary(kept.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        var result = items.compactMap { item -> MiniReelItem? in
            guard item.kind == kind else { return item }
            if let known, !known.contains(item.itemID) { return item }
            return live[item.itemID]
        }
        let present = Set(result.filter { $0.kind == kind }.map(\.itemID))
        result += kept.filter { !present.contains($0.itemID) }
        return renumbered(result)
    }

    /// The reel without the Highlights items that `live` (every candidate of
    /// the batches still remembered and of the run on screen) does not hold:
    /// candidates of a batch that was generated again.
    static func droppingHighlights(_ items: [MiniReelItem], notIn live: Set<Int64>) -> [MiniReelItem] {
        let kept = items.filter { $0.kind != .highlights || live.contains($0.itemID) }
        return kept.count == items.count ? items : renumbered(kept)
    }

    static func renumbered(_ items: [MiniReelItem]) -> [MiniReelItem] {
        items.enumerated().map { position, item in
            var item = item
            item.position = position
            return item
        }
    }

    /// The reel after a List drop: the items the clip ids name, in that
    /// order (a take's cuts name one item), then anything unnamed.
    static func reordered(_ items: [MiniReelItem], clipIDs: [String]) -> [MiniReelItem] {
        var seen = Set<Key>()
        let keys = clipIDs.compactMap(key(of:)).filter { seen.insert($0).inserted }
        let named = keys.compactMap { key in items.first { $0.key == key } }
        let rest = items.filter { !seen.contains($0.key) }
        return renumbered(named + rest)
    }

    /// The reel with every transcript unit's items next to each other, in
    /// the unit's order (`units`: each unit's pick ids). The block sits
    /// where most of its items already are (the longest run; the first on a
    /// tie), so one passage dragged away comes back to its pick and a clip
    /// dropped among the passages ends up beside the block.
    /// `moved` is the item a drag just placed: the block stays with the
    /// unit's other items, so a passage dragged away never takes its pick
    /// along (and undoing the pick's order puts the reel back as it was).
    static func groupingUnits(_ items: [MiniReelItem], units: [[Int64]], moved: Key? = nil) -> [MiniReelItem] {
        var result = items
        for unit in units where unit.count > 1 {
            let rank = Dictionary(unit.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let indices = result.indices.filter { result[$0].kind == .transcript && rank[result[$0].itemID] != nil }
            guard indices.count > 1 else { continue }
            let staying = indices.filter { result[$0].key != moved }
            var best = (start: staying[0], length: 1), run = (start: staying[0], length: 1)
            for (previous, index) in zip(staying, staying.dropFirst()) {
                run = index == previous + 1 ? (run.start, run.length + 1) : (index, 1)
                if run.length > best.length { best = run }
            }
            let inUnit = Set(indices)
            let members = indices.map { result[$0] }.sorted { (rank[$0.itemID] ?? 0) < (rank[$1.itemID] ?? 0) }
            let at = (0..<best.start).filter { !inUnit.contains($0) }.count
            var rest = result.indices.filter { !inUnit.contains($0) }.map { result[$0] }
            rest.insert(contentsOf: members, at: at)
            result = rest
        }
        return result.map(\.key) == items.map(\.key) ? items : renumbered(result)
    }

    /// Each unit's pick ids in the order the reel now shows them; picks the
    /// reel does not hold (unchecked ones) follow in the order they had.
    /// A unit whose shown picks kept their order is left exactly as it was.
    static func unitOrders(_ items: [MiniReelItem], units: [[Int64]]) -> [[Int64]] {
        units.map { unit in
            guard unit.count > 1 else { return unit }
            let members = Set(unit)
            let shown = items.filter { $0.kind == .transcript && members.contains($0.itemID) }.map(\.itemID)
            guard shown != unit.filter(shown.contains) else { return unit }
            return shown + unit.filter { !shown.contains($0) }
        }
    }

    /// The one item a drag moved between two orders of the same items: the
    /// one without which both read the same. Two neighbours that swapped
    /// both qualify; the one outside every unit is taken, so a clip dragged
    /// into a pick's passages is what moves, not the passage it passed.
    static func movedItem(from old: [MiniReelItem], to new: [MiniReelItem], units: [[Int64]]) -> Key? {
        let before = old.map(\.key), after = new.map(\.key)
        guard before != after, Set(before) == Set(after) else { return nil }
        let inUnits = Set(units.filter { $0.count > 1 }.flatMap { $0 })
        let candidates = after.filter { key in before.filter { $0 != key } == after.filter { $0 != key } }
        return candidates.first { !($0.kind == .transcript && inUnits.contains($0.itemID)) } ?? candidates.first
    }

    static func removing(_ items: [MiniReelItem], clipID: String) -> [MiniReelItem] {
        guard let key = key(of: clipID) else { return items }
        return renumbered(items.filter { $0.key != key })
    }

    /// The item's place in its loaded section's list (Q&A exchanges,
    /// transcript or fight picks, Highlights candidates), which picks its
    /// colour there; nil when the section is not loaded or does not hold it.
    static func sectionIndex(of item: MiniReelItem, runs: [MiniWizardFlow.FootageKind: MiniWizardRun]) -> Int? {
        guard let run = runs[item.kind] else { return nil }
        switch item.kind {
        case .qa: return run.qa?.sections.firstIndex { $0.id == item.itemID }
        // Picks added as one unit share its row in the list, so its colour.
        case .transcript:
            return run.transcript.flatMap { TranscriptPickUnits.units($0.picks).firstIndex { $0.contains { $0.id == item.itemID } } }
        case .fightMetrics: return run.fight?.picks.firstIndex { $0.id == item.itemID }
        case .highlights: return run.candidates.firstIndex { $0.id == item.itemID }
        }
    }

    /// `sectionIndex` from a loaded section, else the order read ahead for
    /// the sections not loaded (`cached`).
    static func paletteIndex(of item: MiniReelItem, runs: [MiniWizardFlow.FootageKind: MiniWizardRun],
                             cached: [Key: Int]) -> Int? {
        sectionIndex(of: item, runs: runs) ?? cached[item.key]
    }

    /// The saved candidates behind the reel, in reel order, for Generate.
    /// Items whose section is not loaded or whose selection has not been
    /// recorded are left out. `otherHighlights` are the saved candidates of
    /// Highlights batches other than the loaded one (another Length): a
    /// Highlights item its loaded batch does not know resolves there.
    static func candidates(items: [MiniReelItem], runs: [MiniWizardFlow.FootageKind: MiniWizardRun],
                           otherHighlights: [MiniWizardCandidate] = []) -> [MiniWizardCandidate] {
        items.sorted { $0.position < $1.position }.compactMap { item in
            if item.kind == .highlights, !(runs[.highlights]?.candidates.contains { $0.id == item.itemID } ?? false) {
                return otherHighlights.first { $0.id == item.itemID && $0.kept && !$0.take.plan.clips.isEmpty }
            }
            guard let run = runs[item.kind] else { return nil }
            let saved = run.candidates.filter { $0.kept && !$0.take.plan.clips.isEmpty }
            switch item.kind {
            case .qa:
                return saved.first { $0.take.sceneIDs.first == item.itemID }
            case .transcript, .fightMetrics:
                return saved.first { $0.take.plan.clips.contains { $0.miniPickID == item.itemID } }
            case .highlights:
                return saved.first { $0.id == item.itemID }
            }
        }
    }
}
