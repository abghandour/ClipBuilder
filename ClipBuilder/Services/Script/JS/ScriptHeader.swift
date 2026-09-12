import Foundation

/// Values only: validation has no AppStore, database, service or hydration owner.
nonisolated struct ScriptCapture: Sendable {
    var document: TimelineDocument
    var library: ScriptLibrarySnapshot
    var selection: TimelineSelection?
    var playhead: Double
    var focusedTrack: Int?
    var revision: Int
    var timelineID: Int64?
    var profile: String

    @MainActor init(model: BuilderTimelineModel, library: ScriptLibrarySnapshot) {
        document = model.document; self.library = library; selection = model.selection
        playhead = model.playhead; focusedTrack = model.focusedTrack
        revision = model.revision; timelineID = model.timelineID; profile = model.profileName
    }

    @MainActor func matches(_ model: BuilderTimelineModel) -> Bool {
        revision == model.revision && timelineID == model.timelineID && profile == model.profileName
    }
}

nonisolated struct ScriptHeader: Sendable {
    struct Parameter: Sendable {
        var name: String
        var type: String
        var label: String?
        var min: Double?
        var max: Double?
        var step: Double?
        var choices: [String]?
        var defaultValue: ScriptValue?
    }
    struct Requirement: Sendable {
        var kind: BuilderPrerequisiteKind
        var video: ScriptValue
    }
    var name: String
    var description: String
    var mode: String
    var params: [Parameter]
    var requires: [Requirement]

    static func parse(_ source: String) throws -> Self {
        guard source.utf8.count <= 256 * 1024 else { throw ScriptError.invalid("Source exceeds 256 KiB.") }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = "/** clipbuilder-script"
        guard text.hasPrefix(marker), let end = text.range(of: "*/") else {
            throw ScriptError.invalid("Expected a leading /** clipbuilder-script strict JSON header */.")
        }
        let json = String(text[text.index(text.startIndex, offsetBy: marker.count)..<end.lowerBound])
        let value = try ScriptStrictJSON.decode(Data(json.utf8))
        let root = try fields(value, allowed: ["name", "description", "mode", "params", "requires"])
        let name = try string(root["name"]), description = try string(root["description"])
        let mode = try string(root["mode"])
        guard ["edit", "find"].contains(mode),
              case .array(let rawParams) = root["params"], case .array(let rawRequires) = root["requires"],
              rawRequires.count <= 12, mode == "edit" || rawRequires.isEmpty else {
            throw ScriptError.invalid("Invalid mode, params or requires.")
        }
        var names: Set<String> = []
        let params = try rawParams.map { value -> Parameter in
            let fields = try fields(value, allowed: ["name", "type", "label", "min", "max", "step", "choices", "default"])
            let name = try string(fields["name"]), type = try string(fields["type"])
            guard identifier(name), names.insert(name).inserted,
                  ["string", "number", "boolean", "choice", "clip", "scene", "track", "time"].contains(type) else {
                throw ScriptError.invalid("Parameter names must be unique ASCII identifiers with a known type.")
            }
            let numeric = ["number", "time", "track"].contains(type)
            guard numeric || fields["min"] == nil && fields["max"] == nil && fields["step"] == nil,
                  type == "choice" || fields["choices"] == nil else {
                throw ScriptError.invalid("Fields do not apply to this parameter type.")
            }
            let low = try number(fields["min"]), high = try number(fields["max"]), step = try number(fields["step"])
            guard low == nil || high == nil || low! <= high!, step == nil || step! > 0 else {
                throw ScriptError.invalid("Expected ordered bounds and a positive step.")
            }
            var choices: [String]?
            if type == "choice" {
                guard case .array(let items) = fields["choices"] else { throw ScriptError.invalid("Choices are required.") }
                choices = try items.map { try string($0) }
                guard let choices, !choices.isEmpty, Set(choices).count == choices.count else {
                    throw ScriptError.invalid("Choices must be distinct and nonempty.")
                }
            }
            let parameter = Parameter(name: name, type: type, label: try fields["label"].map { try string($0) },
                                      min: low, max: high, step: step, choices: choices, defaultValue: fields["default"])
            if let value = parameter.defaultValue { try validate(value, parameter: parameter, capture: nil) }
            return parameter
        }
        let requires = try rawRequires.map { value -> Requirement in
            let fields = try fields(value, allowed: ["kind", "video"])
            guard let kind = BuilderPrerequisiteKind(rawValue: try string(fields["kind"])), let video = fields["video"] else {
                throw ScriptError.invalid("Invalid prerequisite.")
            }
            switch video {
            case .string(let reference):
                guard reference.hasPrefix("$"), names.contains(String(reference.dropFirst())) else {
                    throw ScriptError.invalid("Prerequisite references an undeclared parameter.")
                }
            case .number(let id):
                guard safeID(id) else { throw ScriptError.invalid("Invalid video ID.") }
            default: throw ScriptError.invalid("Expected a video ID or $parameter.")
            }
            return Requirement(kind: kind, video: video)
        }
        return Self(name: name, description: description, mode: mode, params: params, requires: requires)
    }

    func resolve(_ supplied: Data = Data("{}".utf8), capture: ScriptCapture) throws -> (Data, [BuilderCommand]) {
        guard supplied.count <= 64 * 1024 else { throw ScriptError.invalid("Parameters exceed 64 KiB.") }
        let values = try Self.fields(ScriptStrictJSON.decode(supplied), allowed: Set(params.map(\.name)))
        var resolved: [String: ScriptValue] = [:]
        for parameter in params {
            guard let value = values[parameter.name] ?? parameter.defaultValue
                    ?? (parameter.type == "time" ? .number(capture.playhead) : nil) else {
                throw ScriptError.invalid("Missing sample or value for parameter: " + parameter.name)
            }
            try Self.validate(value, parameter: parameter, capture: capture)
            resolved[parameter.name] = value
        }
        var targets: Set<String> = []
        let commands = try requires.map { requirement -> BuilderCommand in
            let value: ScriptValue?
            if case .string(let reference) = requirement.video { value = resolved[String(reference.dropFirst())] }
            else { value = requirement.video }
            guard case .number(let number) = value, Self.safeID(number),
                  capture.library.videos.contains(where: { $0.id == Int64(number) }),
                  targets.insert(requirement.kind.rawValue + ":" + String(Int64(number))).inserted else {
                throw ScriptError.invalid("Prerequisites require distinct captured video targets.")
            }
            switch requirement.kind {
            case .transcript: return .ensureTranscript(video: Int64(number))
            case .people: return .ensurePeople(video: Int64(number))
            case .analysis: return .ensureAnalysis(video: Int64(number))
            }
        }
        let data = try JSONEncoder().encode(resolved)
        guard data.count <= 64 * 1024 else { throw ScriptError.invalid("Parameters exceed 64 KiB.") }
        return (data, commands)
    }

    private static func validate(_ value: ScriptValue, parameter p: Parameter, capture: ScriptCapture?) throws {
        switch (p.type, value) {
        case ("string", .string): break
        case ("boolean", .bool): break
        case ("choice", .string(let value)):
            guard p.choices?.contains(value) == true else { throw ScriptError.invalid("Invalid choice: " + p.name) }
        case ("clip", .string(let value)):
            guard let uuid = UUID(uuidString: value),
                  capture == nil || capture!.document.videoTrack.contains(where: { $0.uid == uuid }) else {
                throw ScriptError.invalid("Clip is not in the captured timeline.")
            }
        case ("scene", .number(let value)):
            guard safeID(value), capture == nil || capture!.library.scenes.contains(where: { $0.id == Int64(value) }) else {
                throw ScriptError.invalid("Scene is not in the captured project.")
            }
        case ("number", .number(let value)), ("time", .number(let value)), ("track", .number(let value)):
            guard value.isFinite, abs(value) <= 9_007_199_254_740_991,
                  p.min == nil || value >= p.min!, p.max == nil || value <= p.max! else {
                throw ScriptError.invalid("Parameter is outside its range: " + p.name)
            }
            if let step = p.step {
                let units = (value - (p.min ?? 0)) / step
                guard units.isFinite, abs(units - units.rounded()) <= 1e-8 else {
                    throw ScriptError.invalid("Parameter does not align to its step: " + p.name)
                }
            }
            if p.type == "time", !(0...86400).contains(value) { throw ScriptError.invalid("Time is outside 0…86400.") }
            if p.type == "track" {
                guard safeID(value), capture == nil || value < Double(capture!.document.trackCount) else {
                    throw ScriptError.invalid("Track is not visible.")
                }
            }
        default: throw ScriptError.invalid("Wrong parameter type: " + p.name)
        }
    }

    private static func safeID(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 9_007_199_254_740_991 && value.rounded() == value
    }
    private static func identifier(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII && (first.isLetter || first == "_" || first == "$") else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") }
    }
    private static func fields(_ value: ScriptValue, allowed: Set<String>) throws -> [String: ScriptValue] {
        guard case .object(let fields) = value, Set(fields.keys).isSubset(of: allowed) else {
            throw ScriptError.invalid("Unexpected JSON fields.")
        }
        return fields
    }
    private static func string(_ value: ScriptValue?) throws -> String {
        guard case .string(let value) = value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScriptError.invalid("Expected a nonempty string.")
        }
        return value
    }
    private static func number(_ value: ScriptValue?) throws -> Double? {
        guard let value else { return nil }
        guard case .number(let number) = value, number.isFinite else { throw ScriptError.invalid("Expected a finite number.") }
        return number
    }
}

/// A small structural scanner detects duplicate keys before Foundation decoding
/// can collapse them. Foundation remains responsible for the full JSON grammar.
nonisolated enum ScriptStrictJSON {
    static func decode(_ data: Data) throws -> ScriptValue {
        var scanner = Scanner(bytes: Array(data))
        try scanner.value(depth: 0)
        scanner.whitespace()
        guard scanner.index == scanner.bytes.count else { throw ScriptError.invalid("Trailing JSON data.") }
        return try JSONDecoder().decode(ScriptValue.self, from: data)
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        mutating func whitespace() {
            while index < bytes.count, [9,10,13,32].contains(bytes[index]) { index += 1 }
        }
        mutating func consume(_ byte: UInt8) throws {
            whitespace()
            guard index < bytes.count, bytes[index] == byte else { throw ScriptError.invalid("Malformed strict JSON.") }
            index += 1
        }
        mutating func string() throws -> String {
            whitespace()
            let start = index
            try consume(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 92 { index += 1 }
                else if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
            }
            throw ScriptError.invalid("Unterminated JSON string.")
        }
        mutating func value(depth: Int) throws {
            guard depth <= 32 else { throw ScriptError.invalid("JSON depth exceeds 32.") }
            whitespace()
            guard index < bytes.count else { throw ScriptError.invalid("Missing JSON value.") }
            switch bytes[index] {
            case 123:
                index += 1; whitespace()
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                var keys: Set<String> = []
                while true {
                    let key = try string()
                    guard keys.insert(key).inserted else { throw ScriptError.invalid("Duplicate JSON key: " + key) }
                    try consume(58); try value(depth: depth + 1); whitespace()
                    if index < bytes.count, bytes[index] == 125 { index += 1; return }
                    try consume(44)
                }
            case 91:
                index += 1; whitespace()
                if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); whitespace()
                    if index < bytes.count, bytes[index] == 93 { index += 1; return }
                    try consume(44)
                }
            case 34: _ = try string()
            default:
                let start = index
                while index < bytes.count, ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw ScriptError.invalid("Missing JSON value.") }
            }
        }
    }
}
