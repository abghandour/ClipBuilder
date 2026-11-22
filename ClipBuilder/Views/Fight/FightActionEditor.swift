import SwiftUI

struct FightActionEditor: View {
    let event: FightEventRecord
    /// The saved row a correction is made against; `event` is what the list
    /// shows, which for a submission chain carries the chain's end and result.
    let stored: FightEventRecord
    let correction: FightCorrectionRecord?
    let adding: Bool
    let roster: [VideoPersonRecord]
    let people: [PersonRecord]
    let playback: FightActionPlayback
    let duration: Double
    let onSaved: () async -> Void
    @Environment(AppStore.self) private var store
    @State private var draft: FightEventRecord
    @State private var technique: String
    @State private var limb: String
    @State private var target: String
    @State private var saving = false
    @State private var error: String?

    init(event: FightEventRecord, stored: FightEventRecord? = nil, correction: FightCorrectionRecord?, adding: Bool = false,
         roster: [VideoPersonRecord], people: [PersonRecord], playback: FightActionPlayback,
         duration: Double, onSaved: @escaping () async -> Void) {
        self.event = event
        self.stored = stored ?? event
        self.correction = correction
        self.adding = adding
        self.roster = roster
        self.people = people
        self.playback = playback
        self.duration = duration
        self.onSaved = onSaved
        _draft = State(initialValue: event)
        let detail = StrikeDetail(event.detail)
        _technique = State(initialValue: detail?.technique.rawValue ?? "")
        _limb = State(initialValue: detail?.limb?.rawValue ?? "")
        _target = State(initialValue: detail?.target?.rawValue ?? "")
    }

    private var keys: [String] { Array(Set(roster.map(\.key) + [event.fighterKey, ""])).sorted() }
    private var strike: Bool { StrikeStatsSummary.strikeFamily.contains(draft.action) }
    private var attempt: Bool { draft.action.hasSuffix("_attempt") }
    /// Where the attacker stands in the picture. Given to the other fighter,
    /// the strike comes from the other side: the highlight is looked for there.
    private var frameSide: StrikeDetail.Side? {
        guard let side = StrikeDetail(event.detail)?.frameSide else { return nil }
        guard draft.fighterKey != event.fighterKey, !draft.fighterKey.isEmpty, !event.fighterKey.isEmpty else { return side }
        return side == .left ? .right : .left
    }
    private var final: FightEventRecord {
        var result = draft
        if strike {
            result.detail = StrikeDetail.Technique(rawValue: technique).map {
                StrikeDetail(technique: $0, limb: StrikeDetail.Side(rawValue: limb),
                             target: StrikeDetail.Target(rawValue: target), frameSide: frameSide).encoded
            }
            result.endTime = nil
            result.outcome = nil
        } else if !attempt { result.detail = nil; result.endTime = nil; result.outcome = nil }
        result.points = FightScoring.points(for: result.action, outcome: result.outcome)
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(adding ? "Add action" : "Selected action").font(.headline).lineLimit(1).fixedSize()
            HStack {
                Picker("Fighter", selection: $draft.fighterKey) {
                    ForEach(keys, id: \.self) { key in Text(name(key)).tag(key) }
                }
                Picker("Action", selection: $draft.action) {
                    ForEach(FightScoring.actionKeys.filter { StrikeStatsSummary.strikeFamily.contains($0) || ["takedown", "takedown_attempt", "submission_attempt"].contains($0) }, id: \.self) { action in
                        Text(FightScoring.actionPoints.first { $0.action == action }?.label ?? action).tag(action)
                    }
                }
            }
            if strike {
                HStack {
                    Picker("Technique", selection: $technique) {
                        Text("Unknown").tag("")
                        ForEach(StrikeDetail.Technique.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                    }
                    Picker("Limb", selection: $limb) {
                        Text("Unknown").tag(""); Text("Left").tag("left"); Text("Right").tag("right")
                    }
                }
                Picker("Landed on", selection: $target) {
                    Text("Unknown").tag("")
                    ForEach(StrikeDetail.Target.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                }
            }
            if attempt {
                Picker("Outcome", selection: $draft.outcome) {
                    Text("Unresolved").tag(Optional("unresolved"))
                    Text("Defended").tag(Optional("defended"))
                    Text("Completed").tag(Optional("completed"))
                    Text("Unknown").tag(String?.none)
                }
                if draft.action == "submission_attempt" {
                    Picker("Hold", selection: $draft.detail) {
                        Text("Unknown").tag(String?.none)
                        ForEach(SubmissionHold.allCases, id: \.rawValue) { Text($0.rawValue).tag(Optional($0.rawValue)) }
                    }
                }
                HStack {
                    TextField("End (seconds)", value: $draft.endTime, format: .number.precision(.fractionLength(2)))
                    Button("End at playhead") { draft.endTime = playback.time }
                }
                Picker("Target fighter", selection: $draft.targetKey) {
                    Text("Unattributed").tag(String?.none)
                    ForEach(keys.filter { !$0.isEmpty }, id: \.self) { Text(name($0)).tag(Optional($0)) }
                }
            }
            HStack {
                TextField("Time (seconds)", value: $draft.time, format: .number.precision(.fractionLength(2)))
                Button("−1 frame") { draft.time = max(0, draft.time - playback.frameDuration) }
                Button("+1 frame") { draft.time = min(duration, draft.time + playback.frameDuration) }
            }
            Button("Set to playhead") { draft.time = playback.time }
            HStack {
                if adding {
                    Button("Add action") { save { try await store.addFightEvent(final) } }
                } else {
                    Button("Save changes") { save { try await store.correctFightEvent(stored, replacement: final) } }
                        .disabled(final == event)
                    Button("Correct", systemImage: "checkmark") { save { try await store.confirmFightEvent(stored) } }
                        .help("Confirm the saved action is correct")
                        .disabled(final != event)
                    Button("Not an action") { save { try await store.removeFightEvent(stored) } }
                }
            }
            if let correction {
                Button("Undo correction") { save { try await store.undoFightCorrection(correction) } }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(nil).fixedSize(horizontal: false, vertical: true) }
        }
        .controlSize(.small)
        .lineLimit(1).fixedSize(horizontal: false, vertical: true)
        .disabled(saving || store.fightScoringInFlight.contains(event.videoID))
        .onChange(of: draft.action) {
            draft.detail = nil
            draft.outcome = attempt ? "unresolved" : nil
            draft.endTime = attempt ? max(draft.time, playback.time) : nil
        }
    }

    private func name(_ key: String) -> String {
        key.isEmpty ? "Unattributed" : roster.first { $0.key == key }?.displayName
            ?? people.first { $0.key == key }?.displayName ?? key
    }

    private func save(_ operation: @escaping () async throws -> Void) {
        guard final.time <= duration, final.endTime.map({ $0 <= duration }) ?? true else {
            error = "The action must fall within this video."
            ErrorLog.record("Fight Action correction", error!)
            return
        }
        playback.pause()
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do { try await operation(); await onSaved() }
            catch { self.error = error.localizedDescription }
        }
    }
}
