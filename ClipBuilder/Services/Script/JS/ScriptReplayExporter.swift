import Foundation

nonisolated struct ScriptReplayExport: Sendable {
    var source: String?
    var reason: String?
}

@MainActor
enum ScriptReplayExporter {
    static func verify(_ transcript: ScriptReplayTranscript, name: String) async -> ScriptReplayExport {
        do {
            if let reason = transcript.disabledReason { throw ScriptError.invalid(reason) }
            guard let expected = transcript.expectedDiff else { throw ScriptError.invalid("Missing completed replay provenance.") }
            var writer = Writer(capture: transcript.capture)
            let source = try writer.source(transcript.entries, name: name)
            let header = try ScriptHeader.parse(source)
            let capture = transcript.capture
            let (params, requirements) = try header.resolve(capture: capture)
            let live = BuilderTimelineModel(mode: .transient)
            capture.library.withLayouts {
                live.seed(document: capture.document, scenes: capture.library.scenes,
                          driveBackedPaths: capture.driveBackedPaths, selection: capture.selection,
                          playhead: capture.playhead, focusedTrack: capture.focusedTrack, zoom: capture.zoom)
            }
            let session = BuilderScriptSession(live: live, library: capture.library, ownsHydration: false)
            defer { session.discard() }
            let prerequisites = transcript.entries.filter { $0.steps.first?.command.prerequisite != nil }
            var nextPrerequisite = 0
            let run = ScriptRunModel(session: session, header: header, params: params, confirmed: requirements,
                ensure: { steps in
                    guard nextPrerequisite < prerequisites.count,
                          prerequisites[nextPrerequisite].steps == steps else {
                        return .init(outcomes: [.refused(code: "replay", reason: "Missing prerequisite provenance.")], completed: false, hasDocumentChanges: false)
                    }
                    defer { nextPrerequisite += 1 }
                    return session.replayPrerequisite(prerequisites[nextPrerequisite])
                })
            await run.run(source: source)
            guard run.diagnostic == nil, session.state == .completed,
                  nextPrerequisite == prerequisites.count else {
                throw ScriptError.invalid("Unverifiable equivalence: " + (run.diagnostic?.reason ?? "Replay did not complete."))
            }
            let original = transcript.entries.filter { $0.steps.first?.command.prerequisite == nil && !$0.steps.isEmpty }
            let replayed = session.replay.entries.filter { $0.steps.first?.command.prerequisite == nil && !$0.steps.isEmpty }
            guard original.count == replayed.count else { throw ScriptError.invalid("Unverifiable equivalence: call boundaries changed.") }
            var renaming: [String: String] = [:]
            var reverse: [String: String] = [:]
            let baselineIDs = Set(Writer.uuids(ScriptValue.stored(capture.document)))
            for (left, right) in zip(original, replayed) {
                guard left.result.outcomes.count == right.result.outcomes.count else { throw ScriptError.invalid("Unverifiable outcome provenance.") }
                for (a, b) in zip(left.result.outcomes, right.result.outcomes) {
                    guard Set(a.createdIDs.keys) == Set(b.createdIDs.keys) else { throw ScriptError.invalid("Unresolved generated IDs.") }
                    for key in a.createdIDs.keys {
                        guard let old = a.createdIDs[key], let new = b.createdIDs[key] else { continue }
                        if baselineIDs.contains(old) {
                            guard new == old else { throw ScriptError.invalid("Replay changed a baseline identity.") }
                        }
                        if let prior = renaming[new], prior != old { throw ScriptError.invalid("Inconsistent generated ID renaming.") }
                        if let prior = reverse[old], prior != new { throw ScriptError.invalid("Inconsistent generated ID renaming.") }
                        renaming[new] = old; reverse[old] = new
                    }
                }
            }
            let actual = session.diff()
            guard normalize(actual, renaming: renaming) == normalize(expected, renaming: [:]) else {
                throw ScriptError.invalid("Unverifiable equivalence: replay produced a different normalized diff.")
            }
            return .init(source: source)
        } catch { return .init(reason: error.localizedDescription) }
    }

    private static func normalize(_ diff: TimelineDiff, renaming: [String: String]) -> TimelineDiff {
        func string(_ value: String) -> String {
            var result = value
            for key in renaming.keys.sorted() { result = result.replacingOccurrences(of: key, with: renaming[key] ?? key) }
            return result
        }
        func value(_ input: ScriptValue) -> ScriptValue {
            switch input {
            case .string(let text): return .string(string(text))
            case .array(let items): return .array(items.map(value))
            case .object(let fields): return .object(Dictionary(uniqueKeysWithValues: fields.map { (string($0.key), value($0.value)) }))
            default: return input
            }
        }
        var result = diff
        result.changes = diff.changes.map {
            .init(path: string($0.path), kind: $0.kind, before: $0.before.map(value), after: $0.after.map(value))
        }.sorted { $0.path < $1.path }
        return result
    }

    private struct Writer {
        let capture: ScriptCapture
        var references: [String: String] = [:]
        var aliases: [String: String] = [:]
        var parameters: [ScriptValue] = []
        var parameterNames: [String: String] = [:]
        var sequence = 0
        var selectedID: String?

        static func uuids(_ value: ScriptValue) -> [String] {
            switch value {
            case .string(let text): UUID(uuidString: text) == nil ? [] : [text]
            case .array(let items): items.flatMap(uuids)
            case .object(let fields): fields.values.flatMap(uuids)
            default: []
            }
        }

        func json(_ value: ScriptValue) throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }

        mutating func parameter(_ value: ScriptValue, type: String, key: String) -> String {
            if let name = parameterNames[key] { return "params." + name }
            let name = type + String(parameters.count + 1)
            parameterNames[key] = name
            parameters.append(.object(["name": .string(name), "type": .string(type), "default": value]))
            return "params." + name
        }

        mutating func expression(_ value: ScriptValue, key: String = "", op: String = "") throws -> String {
            switch value {
            case .object(let fields):
                let operation: String
                if case .string(let name) = fields["op"] { operation = name } else { operation = op }
                return try "{" + fields.keys.sorted().map { name in
                    try json(.string(name)) + ":" + expression(fields[name] ?? .null, key: name, op: operation)
                }.joined(separator: ",") + "}"
            case .array(let items):
                return try "[" + items.map { try expression($0, key: key, op: op) }.joined(separator: ",") + "]"
            case .number(let id) where key == "scene":
                guard capture.library.scenes.contains(where: { Double($0.id) == id }) else { throw ScriptError.invalid("Missing baseline scene provenance.") }
                return parameter(value, type: "scene", key: "scene:\(id)")
            case .string(let text):
                // Only reference-bearing fields are rewritten; user text stays literal.
                let reference = ["clip", "block", "overlay", "sound", "ids"].contains(key)
                guard reference, !(key == "sound" && op == "add_sound") else { return try json(value) }
                if let replacement = aliases[text] { return try json(.string(replacement)) }
                if text == "selected" || text == "$selected" {
                    guard let selectedID else { throw ScriptError.invalid("Missing selected-item provenance.") }
                    return try expression(.string(selectedID), key: key, op: op)
                }
                if text.hasPrefix("$") {
                    guard let replacement = aliases[text] else { throw ScriptError.invalid("Unresolved generated IDs: " + text) }
                    return try json(.string(replacement))
                }
                let identity = UUID(uuidString: text)?.uuidString ?? text
                if let replacement = references[identity] { return try json(.string(replacement)) }
                if capture.document.videoTrack.contains(where: { $0.uid.uuidString == identity }) {
                    guard key == "clip" || key == "ids" else { throw ScriptError.invalid("Unsupported baseline reference kind: " + key) }
                    return parameter(.string(identity), type: "clip", key: identity)
                }
                if UUID(uuidString: text) != nil {
                    if Self.uuids(ScriptValue.stored(capture.document)).contains(identity) {
                        throw ScriptError.invalid("Unsupported baseline reference kind: " + key + " (sounds/overlays/crops cannot be parameterized).")
                    }
                    throw ScriptError.invalid("Unresolved generated IDs: " + text)
                }
                throw ScriptError.invalid("Missing reference provenance: " + key)
            default: return try json(value)
            }
        }

        mutating func source(_ entries: [ScriptReplayTranscript.Entry], name: String) throws -> String {
            var prefix: [String] = [], lists: [String] = [], requirements: [ScriptValue] = []
            var mutationSeen = false
            for entry in entries where !entry.steps.isEmpty {
                guard entry.result.completed, entry.steps.count == entry.result.outcomes.count else {
                    throw ScriptError.invalid("Missing successful-list provenance.")
                }
                if let requirement = entry.steps.first?.command.prerequisite {
                    guard !mutationSeen, entry.steps.count == 1, entry.libraryAfterPrerequisite != nil else {
                        throw ScriptError.invalid("Missing prerequisite provenance or late prerequisite.")
                    }
                    requirements.append(.object(["kind": .string(requirement.kind.rawValue), "video": .number(Double(requirement.video))]))
                    prefix.append("builder.ops.ensure_\(requirement.kind.rawValue)({video:\(requirement.video)});")
                    continue
                }
                selectedID = entry.selection?.uid.uuidString
                var steps: [String] = []
                for (step, outcome) in zip(entry.steps, entry.result.outcomes) {
                    if case .query = step.command {} else { mutationSeen = true }
                    let command = try JSONDecoder().decode(ScriptValue.self, from: JSONEncoder().encode(step.command))
                    let rendered = try expression(command)
                    var binding: String?
                    if !outcome.createdIDs.isEmpty {
                        sequence += 1
                        let name = "replay" + String(sequence)
                        binding = name
                        for member in outcome.createdIDs.keys.sorted() {
                            if let id = outcome.createdIDs[member] { references[id] = "$" + name + "." + member }
                        }
                        if let old = step.bind {
                            aliases = aliases.filter { $0.key != "$" + old && !$0.key.hasPrefix("$" + old + ".") }
                            for member in outcome.createdIDs.keys { aliases["$" + old + "." + member] = "$" + name + "." + member }
                            for preferred in ["tail", "clip", "piece1", "overlay", "block", "sound"] where outcome.createdIDs[preferred] != nil {
                                aliases["$" + old] = "$" + name + "." + preferred; break
                            }
                        }
                    } else if step.bind != nil { throw ScriptError.invalid("Missing binding provenance.") }
                    steps.append("{command:" + rendered + (try binding.map { ",bind:" + (try json(.string($0))) } ?? "") + "}")
                }
                lists.append("builder.run([" + steps.joined(separator: ",") + "]);")
            }
            let header = ScriptValue.object(["name": .string(name.isEmpty ? "Saved run" : name),
                "description": .string("Replay of the verified Wizard run."), "mode": .string("edit"),
                "params": .array(parameters), "requires": .array(requirements)])
            // Prevent a user-supplied name ending the JavaScript comment.
            let metadata = try json(header).replacingOccurrences(of: "*/", with: "*\\/")
            let source = "/** clipbuilder-script\n" + metadata + "\n*/\n" + (prefix + lists).joined(separator: "\n") + "\n"
            guard source.utf8.count <= 256 * 1024 else { throw ScriptError.invalid("Export source exceeds 256 KiB.") }
            return source
        }
    }
}
