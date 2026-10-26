import Foundation

/// Manual Express editing on source clocks. Piece identity disambiguates repeated passages.
nonisolated enum MiniBRollRules {
    struct Piece: Identifiable, Equatable, Sendable {
        struct ID: Hashable, Sendable {
            var selectionID: Int64
            var clipIndex: Int
        }
        var id: ID
        var takeID: Int64
        var sceneID: Int64
        var range: ClosedRange<Double>
        var cuts: [BRollCut]
    }

    struct Word: Identifiable, Equatable, Sendable {
        var id: Int
        var pieceID: Piece.ID
        var text: String
        var start: Double
        var end: Double
    }

    struct Block: Identifiable, Equatable, Sendable {
        var id: Int
        var speaker: String?
        var words: [Word]
    }

    struct Transcript: Equatable, Sendable {
        var blocks: [Block] = []
        var words: [Word] = []
    }

    struct Selection: Equatable, Sendable {
        var pieceID: Piece.ID
        var range: ClosedRange<Double>
        var text: String
    }

    static func pieces(_ candidates: [MiniWizardCandidate]) -> [Piece] {
        candidates.filter(\.kept).flatMap { candidate in
            candidate.take.plan.clips.enumerated().compactMap { index, clip -> Piece? in
                guard clip.start.isFinite, clip.end.isFinite, clip.end > clip.start else { return nil }
                return Piece(id: .init(selectionID: candidate.id, clipIndex: index), takeID: candidate.take.id,
                    sceneID: clip.sceneID, range: clip.start...clip.end,
                    cuts: retained(clip.brollCuts ?? [], in: clip.start...clip.end))
            }
        }
    }

    /// Re-finding the same footage retains only cutaways whose anchored words remain.
    static func preservingCuts(in plan: WizardPlan, from previous: [WizardPlan]) -> WizardPlan {
        var result = plan
        let old = previous.flatMap(\.clips)
        for index in result.clips.indices {
            let clip = result.clips[index]
            guard clip.end > clip.start else { continue }
            let matches = old.filter { $0.sceneID == clip.sceneID && $0.start < clip.end && $0.end > clip.start }
            let exact = matches.first { $0.start == clip.start && $0.end == clip.end }
            let cuts = exact?.brollCuts ?? matches.flatMap { $0.brollCuts ?? [] }
            var seen = Set<UUID>()
            result.clips[index].brollCuts = retained(cuts, in: clip.start...clip.end)
                .filter { seen.insert($0.id).inserted }
        }
        return result
    }

    static func pieces(_ run: MiniWizardRun) -> [Piece] {
        pieces(run.candidates).compactMap { piece in
            let range: ClosedRange<Double>?
            switch run.footageKind {
            case .qa:
                range = run.qa?.sections.first { $0.id == piece.sceneID && run.qa?.kept.contains($0.id) == true }?.range
            case .transcript:
                let pickID = run.candidates.first { $0.id == piece.id.selectionID }?
                    .take.plan.clips[piece.id.clipIndex].miniPickID
                range = run.transcript?.picks.first { $0.id == pickID }?.range
            case .highlights, .fightMetrics: range = piece.range
            }
            guard let range else { return nil }
            var result = piece
            result.range = range
            result.cuts = retained(piece.cuts, in: range)
            return result
        }
    }

    /// Reuses Q&A's speaker resolution, then joins rows solely by speaker.
    /// Iterating pieces (not time sorting) preserves the reel's chosen order.
    static func transcript(pieces: [Piece], source: TranscriptQATrim.Transcript) -> Transcript {
        var result = Transcript()
        for piece in pieces {
            for line in source.lines {
                for token in line.words where token.start >= piece.range.lowerBound && token.end <= piece.range.upperBound {
                    let word = Word(id: result.words.count, pieceID: piece.id, text: token.text,
                                    start: token.start, end: token.end)
                    result.words.append(word)
                    if let last = result.blocks.indices.last, result.blocks[last].speaker == line.speaker {
                        result.blocks[last].words.append(word)
                    } else {
                        result.blocks.append(Block(id: result.blocks.count, speaker: line.speaker, words: [word]))
                    }
                }
            }
        }
        return result
    }

    static func selection(anchor: Int, target: Int, transcript: Transcript) -> Selection? {
        guard let first = transcript.words.first(where: { $0.id == anchor }) else { return nil }
        let words = transcript.words.filter { $0.pieceID == first.pieceID }
        guard let lower = words.first?.id, let upper = words.last?.id else { return nil }
        let end = min(upper, max(lower, target))
        let selected = words.filter { $0.id >= min(anchor, end) && $0.id <= max(anchor, end) }
        guard let a = selected.first, let b = selected.last, b.end > a.start else { return nil }
        return Selection(pieceID: first.pieceID, range: a.start...b.end,
                         text: selected.map(\.text).joined(separator: " "))
    }

    static func makeCut(selection: Selection, piece: Piece, scene: SceneRecord) -> BRollCut? {
        let start = selection.range.lowerBound
        guard selection.pieceID == piece.id, start >= piece.range.lowerBound,
              !piece.cuts.contains(where: { $0.start <= start && start < $0.end }),
              scene.duration.isFinite, scene.duration > 0 else { return nil }
        let next = piece.cuts.filter { $0.start > start }.map(\.start).min() ?? piece.range.upperBound
        let end = min(selection.range.upperBound, piece.range.upperBound, next, start + scene.duration)
        guard end > start else { return nil }
        return BRollCut(start: start, end: end, sceneID: scene.id, sceneOffset: 0,
                        reason: String(selection.text.prefix(240)), origin: .user)
    }

    static func wordEnds(cut: BRollCut, piece: Piece, words: [Word], scene: SceneRecord) -> [Double] {
        let next = piece.cuts.filter { $0.id != cut.id && $0.start >= cut.start }.map(\.start).min()
            ?? piece.range.upperBound
        let limit = min(piece.range.upperBound, next, cut.start + max(0, scene.duration - cut.sceneOffset))
        return Array(Set(words.filter {
            $0.pieceID == piece.id && $0.start >= cut.start && $0.end > cut.start && $0.end <= limit
        }.map(\.end))).sorted()
    }

    static func resized(_ cut: BRollCut, end: Double, piece: Piece, words: [Word], scene: SceneRecord) -> BRollCut {
        let ends = wordEnds(cut: cut, piece: piece, words: words, scene: scene)
        guard end.isFinite, let snapped = ends.min(by: { abs($0 - end) < abs($1 - end) }) else { return cut }
        var result = cut
        result.end = snapped
        result.origin = .user
        return result
    }

    static func replacing(_ cut: BRollCut, scene: SceneRecord) -> BRollCut {
        var result = cut
        result.sceneID = scene.id
        result.sceneOffset = 0
        result.end = min(cut.end, cut.start + max(0, scene.duration))
        result.origin = .user
        return result
    }

    static func offset(_ cut: BRollCut, to offset: Double, scene: SceneRecord) -> BRollCut {
        guard offset.isFinite else { return cut }
        var result = cut
        result.sceneOffset = min(max(0, scene.duration - (cut.end - cut.start)), max(0, offset))
        result.origin = .user
        return result
    }

    /// A removed first/last word invalidates the cut rather than silently moving its anchor.
    static func retained(_ cuts: [BRollCut], in range: ClosedRange<Double>) -> [BRollCut] {
        cuts.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
            && $0.start >= range.lowerBound && $0.end <= range.upperBound }
            .sorted { $0.start < $1.start }
    }
}
