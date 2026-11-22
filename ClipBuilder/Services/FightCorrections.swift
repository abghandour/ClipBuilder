import Foundation

nonisolated struct FightCorrectionRecord: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case edit, remove, add, confirm }
    var id: Int64 = 0
    var videoID: Int64
    var kind: Kind
    var time: Double
    var fighterKey: String
    var action: String
    var detail: String?
    var newTime: Double?
    var newFighterKey: String?
    var newAction: String?
    var newDetail: String?
    var newEndTime: Double?
    var newOutcome: String?
    var newTargetKey: String?
    var createdAt: String?
    /// Local undo snapshot and current binding, kept outside the specified correction schema.
    var original: FightEventRecord?
    var eventID: Int64?
    var generation: Int64?
    /// The other stored rows the corrected action stood for (a repeat of the
    /// same blow, the later rows of a submission chain), deleted with it and
    /// brought back by Undo.
    var siblings: [FightEventRecord]?
    /// Those of `siblings` the reviewer had added by hand. Undo brings each
    /// back with its addition, so the next scoring does not drop it.
    var addedSiblings: [FightEventRecord]?

    init(event: FightEventRecord, kind: Kind, replacement: FightEventRecord? = nil) {
        videoID = event.videoID
        self.kind = kind
        time = event.time
        fighterKey = kind == .add ? "" : event.fighterKey
        action = kind == .add ? "" : event.action
        detail = kind == .add ? nil : event.detail
        original = kind == .add ? nil : event
        eventID = kind == .add ? nil : event.id
        generation = event.generation
        setReplacement(replacement ?? event)
    }

    mutating func setReplacement(_ event: FightEventRecord) {
        newTime = event.time
        newFighterKey = event.fighterKey
        newAction = event.action
        newDetail = event.detail
        newEndTime = event.endTime
        newOutcome = event.outcome
        newTargetKey = event.targetKey
    }
}

nonisolated enum FightCorrections {
    static let tolerance = 0.6

    static func family(_ action: String) -> String {
        if StrikeStatsSummary.strikeFamily.contains(action) { return "strike" }
        if action == "takedown" || action == "takedown_attempt" { return "takedown" }
        return action
    }

    /// The closest action of that fighter and family. Between candidates about
    /// as close, the one logged as the same blow wins: two blows can share a
    /// timestamp. `strict` refuses a candidate known to be something else:
    /// another technique or limb for a strike; for anything without a strike
    /// description (takedowns, submission attempts) another action or hold.
    static func nearest(in events: [FightEventRecord], videoID: Int64, time: Double,
                        fighter: String, action: String, detail: String? = nil, strict: Bool = false,
                        where usable: (Int) -> Bool = { _ in true }) -> Int? {
        let wanted = StrikeDetail(detail)
        func key(_ index: Int) -> (Int, Int, Double, Int64) {
            let distance = abs(events[index].time - time)
            return (Int(distance * 10), events[index].detail == detail ? 0 : 1, distance, events[index].id)
        }
        return events.indices.filter {
            guard usable($0), events[$0].videoID == videoID, events[$0].fighterKey == fighter,
                  family(events[$0].action) == family(action),
                  abs(events[$0].time - time) <= tolerance + 1e-9 else { return false }
            guard strict else { return true }
            if let wanted, let found = StrikeDetail(events[$0].detail) {
                if found.technique != wanted.technique { return false }
                if let a = found.limb, let b = wanted.limb, a != b { return false }
                return true
            }
            if events[$0].action != action { return false }
            if let a = events[$0].detail, let b = detail, a != b { return false }
            return true
        }.min { key($0) < key($1) }
    }

    /// The same action, whatever row holds it: used before a row is put back.
    static func sameAction(_ a: FightEventRecord, _ b: FightEventRecord) -> Bool {
        a.videoID == b.videoID && a.time == b.time && a.fighterKey == b.fighterKey && a.action == b.action
            && a.detail == b.detail && a.endTime == b.endTime && a.outcome == b.outcome && a.targetKey == b.targetKey
    }

    /// The other stored rows the popup shows as one action with this one.
    static func siblings(of index: Int, in events: [FightEventRecord]) -> [Int] {
        let units = StrikeStatsSummary.strikeUnits(events) + StrikeStatsSummary.attemptUnits(events)
        return units.first { $0.members.count > 1 && $0.members.contains(index) }?.members.filter { $0 != index } ?? []
    }

    static func replacement(_ correction: FightCorrectionRecord, base: FightEventRecord? = nil) -> FightEventRecord {
        // An action entered by hand is a current one: without the version it
        // would be counted the legacy way and never join a chain or a repeat.
        var event = base ?? correction.original ?? FightEventRecord(id: -max(1, correction.id), videoID: correction.videoID,
            time: correction.time, fighterKey: correction.fighterKey, action: correction.action, points: 0,
            scoringVersion: AnalysisPipeline.fightScorePass)
        event.time = correction.newTime ?? correction.time
        event.fighterKey = correction.newFighterKey ?? correction.fighterKey
        event.action = correction.newAction ?? correction.action
        event.detail = correction.newDetail
        event.endTime = correction.newEndTime
        event.outcome = correction.newOutcome
        event.targetKey = correction.newTargetKey
        event.points = FightScoring.points(for: event.action, outcome: event.outcome)
        return event
    }

    /// Prefer the reviewed form when a re-score already fixed attribution/time.
    /// Otherwise match the original family and fighter within the specified window.
    static func index(for correction: FightCorrectionRecord, in events: [FightEventRecord], corrected: Bool = false,
                      strict: Bool = false, where usable: (Int) -> Bool = { _ in true }) -> Int? {
        nearest(in: events, videoID: correction.videoID,
                time: corrected ? correction.newTime ?? correction.time : correction.time,
                fighter: corrected ? correction.newFighterKey ?? correction.fighterKey : correction.fighterKey,
                action: corrected ? correction.newAction ?? correction.action : correction.action,
                detail: corrected ? correction.newDetail : correction.detail, strict: strict, where: usable)
    }

    /// What the corrections make of a list of events, and which row each
    /// correction now belongs to.
    struct Resolution: Sendable {
        struct Entry: Sendable {
            var event: FightEventRecord
            /// Its place in the list given, nil for a row a correction added.
            var source: Int?
            var changed: Bool
        }
        var entries: [Entry] = []
        /// Places in the list given whose rows are dropped.
        var removed: [Int] = []
        /// Correction id to its place in `entries`.
        var bound: [Int64: Int] = [:]
        var events: [FightEventRecord] { entries.map(\.event) }
    }

    static func apply(_ corrections: [FightCorrectionRecord], to events: [FightEventRecord]) -> [FightEventRecord] {
        resolve(corrections, in: events).events
    }

    /// - `settled`: places whose rows already carry the corrections (rows kept
    ///   from before a partial retry, rows a sync left alone). A correction
    ///   never changes or removes one; it only finds its own row among them.
    /// - `kept`: stretches of the fight that were not scored again. An action
    ///   removed there is already gone; nothing nearby is removed in its place.
    /// Each row is taken by one correction at most, and a correction covers
    /// every stored row its action stands for.
    static func resolve(_ corrections: [FightCorrectionRecord], in events: [FightEventRecord],
                        settled: Set<Int> = [], kept: [FightSampling.Range] = []) -> Resolution {
        struct Slot { var event: FightEventRecord; var source: Int?; var changed = false; var taken = false; var removed = false }
        var slots = events.enumerated().map { Slot(event: $1, source: $0) }
        var owner: [Int64: Int] = [:]
        func isSettled(_ slot: Int) -> Bool { slots[slot].source.map(settled.contains) ?? false }
        func find(_ correction: FightCorrectionRecord, corrected: Bool = false, strict: Bool = false,
                  settledToo: Bool = false, where fits: (FightEventRecord) -> Bool = { _ in true }) -> Int? {
            index(for: correction, in: slots.map(\.event), corrected: corrected, strict: strict) {
                !slots[$0].taken && !slots[$0].removed && (settledToo || !isSettled($0)) && fits(slots[$0].event)
            }
        }
        /// The rows shown as one action with this one go when it is corrected.
        func absorb(_ slot: Int) {
            guard let source = slots[slot].source else { return }
            for sibling in siblings(of: source, in: events) {
                guard let other = slots.firstIndex(where: { $0.source == sibling }),
                      !slots[other].taken, !slots[other].removed, !isSettled(other) else { continue }
                slots[other].removed = true
            }
        }
        func drop(_ slot: Int) {
            slots[slot].removed = true
            absorb(slot)
        }
        func isKept(_ time: Double) -> Bool { kept.contains { time >= $0.start && time < $0.end } }
        // Confirmations last: one must never take the row an edit or a removal is looking for.
        let ordered = corrections.filter { $0.kind != .confirm }.sorted { $0.id < $1.id }
            + corrections.filter { $0.kind == .confirm }.sorted { $0.id < $1.id }
        for correction in ordered {
            let bound = correction.eventID.flatMap { id in
                slots.indices.first {
                    isSettled($0) && !slots[$0].taken && !slots[$0].removed && slots[$0].event.id == id
                        && correction.generation == slots[$0].event.generation
                }
            }
            let inKept = isKept(correction.time)
            switch correction.kind {
            case .confirm:
                if let slot = bound ?? find(correction, strict: true) ?? find(correction, strict: true, settledToo: true) {
                    slots[slot].taken = true
                    owner[correction.id] = slot
                }
            case .remove:
                // An action edited and then removed may come back in either
                // form; each form is looked for only where the fight was scored again.
                var slot = inKept ? nil : find(correction, strict: true)
                // The corrected form is taken only when it is unmistakably
                // that row: the same description at the same moment.
                if slot == nil, !isKept(correction.newTime ?? correction.time) {
                    slot = find(correction, corrected: true, strict: true) {
                        $0.detail == correction.newDetail && abs($0.time - (correction.newTime ?? correction.time)) <= 0.2
                    }
                }
                if let slot { drop(slot) }
            case .add:
                if let slot = bound ?? find(correction, corrected: true, strict: true, settledToo: true) {
                    slots[slot].taken = true
                    owner[correction.id] = slot
                } else {
                    slots.append(Slot(event: replacement(correction), source: nil, changed: true, taken: true))
                    owner[correction.id] = slots.count - 1
                }
            case .edit:
                if let bound {
                    slots[bound].taken = true
                    owner[correction.id] = bound
                    // The corrected row was kept, and the mistake came back
                    // beside it, scored again in a stretch the retry did cover.
                    if !kept.isEmpty, !inKept, let stale = find(correction, strict: true) { drop(stale) }
                } else if let slot = find(correction) ?? find(correction, corrected: true, strict: true, settledToo: true) {
                    // A re-score may already contain the corrected fighter/time. Reuse
                    // that row only when the original no longer matches.
                    let event = replacement(correction, base: slots[slot].event)
                    if event != slots[slot].event {
                        slots[slot].event = event
                        slots[slot].changed = true
                    }
                    if !isSettled(slot) { absorb(slot) }
                    slots[slot].taken = true
                    owner[correction.id] = slot
                } else {
                    slots.append(Slot(event: replacement(correction), source: nil, changed: true, taken: true))
                    owner[correction.id] = slots.count - 1
                }
            }
        }
        let order = slots.indices.filter { !slots[$0].removed }.sorted {
            (slots[$0].event.time, slots[$0].event.id, $0) < (slots[$1].event.time, slots[$1].event.id, $1)
        }
        var result = Resolution()
        result.entries = order.map { Resolution.Entry(event: slots[$0].event, source: slots[$0].source, changed: slots[$0].changed) }
        result.removed = slots.filter(\.removed).compactMap(\.source)
        for (id, slot) in owner {
            if let place = order.firstIndex(of: slot) { result.bound[id] = place }
        }
        return result
    }

    /// After Team Sync brought a teammate's events: which row each correction
    /// belongs to now, as places in `events`. Nothing is corrected again here.
    /// A teammate's rows stand as sent (two Macs holding different corrections
    /// of one action would otherwise write over each other in turns); the
    /// corrections are applied again by the next scoring on this Mac.
    /// A correction keeps its row while that row exists. Failing that it is
    /// tied only to a row that is exactly what it had made, never to a
    /// neighbour: Undo writes the original over whatever it is tied to.
    /// `sameRows`: the ids that still name the row they named before the
    /// pull. An id freed by a deletion can be handed to an arriving row.
    static func rebind(_ corrections: [FightCorrectionRecord], in events: [FightEventRecord],
                       boundGeneration: Int64, sameRows: Set<Int64>? = nil) -> [Int64: Int] {
        var taken = Set<Int>()
        var result: [Int64: Int] = [:]
        let live = corrections.filter { $0.kind != .remove }.sorted { $0.id < $1.id }
        for correction in live where correction.generation == boundGeneration {
            guard let id = correction.eventID, sameRows?.contains(id) ?? true,
                  let place = events.indices.first(where: { events[$0].id == id && !taken.contains($0) }) else { continue }
            taken.insert(place)
            result[correction.id] = place
        }
        for correction in live where result[correction.id] == nil {
            let made = replacement(correction)
            guard let place = events.indices.first(where: {
                !taken.contains($0) && events[$0].fighterKey == made.fighterKey && events[$0].action == made.action
                    && events[$0].detail == made.detail && events[$0].endTime == made.endTime
                    && events[$0].outcome == made.outcome && events[$0].targetKey == made.targetKey
                    && abs(events[$0].time - made.time) < 0.001
            }) else { continue }
            taken.insert(place)
            result[correction.id] = place
        }
        return result
    }

    static func validate(_ correction: FightCorrectionRecord) throws {
        let event = replacement(correction)
        guard correction.time.isFinite, correction.time >= 0,
              event.time.isFinite, event.time >= 0, FightScoring.actionKeys.contains(event.action),
              event.endTime.map({ $0.isFinite && $0 >= event.time }) ?? true else {
            throw AIError.notConfigured("Enter a valid action and time; an attempt must end at or after its start.")
        }
    }
}
