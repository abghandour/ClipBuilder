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
    static func reconcile(_ items: [MiniReelItem], kind: MiniWizardFlow.FootageKind, kept: [MiniReelItem]) -> [MiniReelItem] {
        let live = Dictionary(kept.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        var result = items.compactMap { item -> MiniReelItem? in
            guard item.kind == kind else { return item }
            return live[item.itemID]
        }
        let present = Set(result.filter { $0.kind == kind }.map(\.itemID))
        result += kept.filter { !present.contains($0.itemID) }
        return renumbered(result)
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

    static func removing(_ items: [MiniReelItem], clipID: String) -> [MiniReelItem] {
        guard let key = key(of: clipID) else { return items }
        return renumbered(items.filter { $0.key != key })
    }

    /// The saved candidates behind the reel, in reel order, for Generate.
    /// Items whose section is not loaded or whose selection has not been
    /// recorded are left out.
    static func candidates(items: [MiniReelItem], runs: [MiniWizardFlow.FootageKind: MiniWizardRun]) -> [MiniWizardCandidate] {
        items.sorted { $0.position < $1.position }.compactMap { item in
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
