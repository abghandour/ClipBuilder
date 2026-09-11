import Foundation

/// Natural JSON values for compact, typed query and mutation payloads.
nonisolated enum ScriptValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String)
    case array([ScriptValue]), object([String: ScriptValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([ScriptValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ScriptValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Reflect stored values instead of the lossy timeline disk codec: that
    /// codec deliberately omits IDs, hydration and several inactive fields.
    static func stored(_ value: Any) -> ScriptValue {
        switch value {
        case let v as String: return .string(v)
        case let v as UUID: return .string(v.uuidString)
        case let v as Bool: return .bool(v)
        case let v as Double: return .number(v)
        case let v as Int: return .number(Double(v))
        case let v as Int64: return .string(String(v))
        default: break
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return mirror.children.first.map { stored($0.value) } ?? .null
        }
        if mirror.displayStyle == .enum { return .string(String(describing: value)) }
        if mirror.displayStyle == .collection || mirror.displayStyle == .set {
            return .array(mirror.children.map { stored($0.value) })
        }
        if mirror.displayStyle == .dictionary {
            var result: [String: ScriptValue] = [:]
            for child in mirror.children {
                let pair = Array(Mirror(reflecting: child.value).children)
                if pair.count == 2 { result[String(describing: pair[0].value)] = stored(pair[1].value) }
            }
            return .object(result)
        }
        if mirror.children.isEmpty { return .string(String(describing: value)) }
        return .object(Dictionary(uniqueKeysWithValues: mirror.children.enumerated().map {
            ($0.element.label ?? String($0.offset), stored($0.element.value))
        }))
    }
}

/// Field-level changes include runtime values and indirect layout effects.
/// IDs key entity arrays so inserting a clip doesn't look like editing every
/// subsequent clip; the explicit order field still detects rearrangement.
nonisolated struct TimelineDiff: Codable, Sendable, Equatable {
    nonisolated struct Change: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable { case added, removed, changed }
        var path: String
        var kind: Kind
        var before: ScriptValue?
        var after: ScriptValue?

        enum CodingKeys: String, CodingKey { case path, kind, before, after }

        init(path: String, kind: Kind, before: ScriptValue?, after: ScriptValue?) {
            self.path = path
            self.kind = kind
            self.before = before
            self.after = after
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            kind = try c.decode(Kind.self, forKey: .kind)
            // Missing keys mean added/removed; explicit JSON null is a stored
            // optional field. decodeIfPresent would erase that distinction.
            before = c.contains(.before) ? try c.decode(ScriptValue.self, forKey: .before) : nil
            after = c.contains(.after) ? try c.decode(ScriptValue.self, forKey: .after) : nil
        }
    }
    var changes: [Change]
    var beforeDuration: Double
    var afterDuration: Double
    var isEmpty: Bool { changes.isEmpty }

    init(before: TimelineDocument, after: TimelineDocument) {
        beforeDuration = before.contentEnd
        afterDuration = after.contentEnd
        changes = []
        Self.compare(Self.fields(before), Self.fields(after), path: "document", into: &changes)
    }

    private static func fields(_ document: TimelineDocument) -> ScriptValue {
        guard case .object(var fields) = ScriptValue.stored(document) else { return .null }
        for key in ["videoTrack", "soundTrack", "textOverlays", "imageOverlays", "overlayBlocks", "cropBlocks"] {
            guard case .array(let items) = fields[key] else { continue }
            var keyed: [String: ScriptValue] = [:]
            var order: [ScriptValue] = []
            for (index, item) in items.enumerated() {
                var id = String(index)
                if case .object(let object) = item, case .string(let uid) = object["uid"] { id = uid }
                keyed[id] = item
                order.append(.string(id))
            }
            fields[key] = .object(keyed)
            fields[key + ".order"] = .array(order)
        }
        if case .array(let tracks) = fields["trackSettings"] {
            fields["trackSettings"] = .object(Dictionary(uniqueKeysWithValues:
                tracks.enumerated().map { (String($0.offset), $0.element) }))
        }
        fields["duration"] = .number(document.contentEnd)
        return .object(fields)
    }

    private static func compare(_ before: ScriptValue?, _ after: ScriptValue?, path: String,
                                into changes: inout [Change]) {
        guard before != after else { return }
        if case .object(let a) = before, case .object(let b) = after {
            for key in Set(a.keys).union(b.keys).sorted() {
                compare(a[key], b[key], path: path + "." + key, into: &changes)
            }
        } else {
            changes.append(Change(path: path, kind: before == nil ? .added : after == nil ? .removed : .changed,
                                  before: before, after: after))
        }
    }
}
