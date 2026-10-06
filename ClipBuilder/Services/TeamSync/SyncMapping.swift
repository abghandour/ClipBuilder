import Foundation
import CryptoKit

/// JSON values stay typed and lossless across an older client's read/edit/write.
nonisolated enum SyncJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Decimal), string(String)
    case array([SyncJSON]), object([String: SyncJSON])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Decimal.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([SyncJSON].self) { self = .array(v) }
        else { self = .object(try value.decode([String: SyncJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

nonisolated struct SyncScope: Sendable, Equatable {
    let teamID: UUID
    let profileID: UUID
}

nonisolated struct SyncCursor: Sendable, Equatable {
    let timestamp: String
    let syncID: String

    var instant: Date {
        get throws {
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(timestamp) { return date }
            throw SyncError.invalidRow("server_updated_at")
        }
    }

    func isAfter(_ other: SyncCursor) throws -> Bool {
        let date = try instant, otherDate = try other.instant
        return date > otherDate || (date == otherDate && syncID > other.syncID)
    }
}

nonisolated enum SyncError: Error, LocalizedError, Equatable {
    case invalidRow(String)
    case scopeMismatch
    case needsUpdate(Int)
    case serverNotReady
    case alreadySyncing
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRow(let field): return "Invalid sync response: \(field)."
        case .scopeMismatch: return "This database is already bound to another team or profile."
        case .needsUpdate(let version): return "Team sync needs a newer app (server schema \(version)). Local work is still available."
        case .serverNotReady: return "The Team server needs its Phase 1 migration. Local work is still available."
        case .alreadySyncing: return "Team sync is already running."
        case .http(let code): return "Team sync request failed (HTTP \(code))."
        }
    }
}

nonisolated enum SyncMapping {
    typealias WireRow = [String: SyncJSON]
    static let table = "wizard_lessons"
    static let columns = ["text", "pinned", "evidence", "provider", "model", "learned_id", "created_at", "updated_at"]

    /// Only explicitly portable local columns are exported. Integer ids and any
    /// local path columns in SQLRow never enter the wire representation.
    static func wire(local: SQLRow?, syncID: String, scope: SyncScope,
                     preserved: WireRow = [:], table: SyncTable = .lessons) throws -> WireRow {
        guard UUID(uuidString: syncID) != nil else { throw SyncError.invalidRow("sync_id") }
        if table.name == "profile_documents", UUID(uuidString: syncID) != scope.profileID { throw SyncError.invalidRow("profile identity") }
        var result = preserved.mapValues(portableJSON)
        if table.name != "ig_comments" { result.removeValue(forKey: "id") }
        result.removeValue(forKey: "server_updated_at")
        result.removeValue(forKey: "updated_by")
        for key in result.keys where isLocalField(key) {
            result.removeValue(forKey: key)
        }
        result["sync_id"] = .string(syncID.lowercased())
        result["team_id"] = .string(scope.teamID.uuidString.lowercased())
        result["profile_id"] = .string(scope.profileID.uuidString.lowercased())
        if let local {
            for column in table.columns {
                switch local[column] ?? .null {
                case .text(let v):
                    if column.hasSuffix("_json"), let json = try? JSONDecoder().decode(SyncJSON.self, from: Data(v.utf8)) {
                        result[column] = .string(try portableJSONString(json))
                    } else { result[column] = .string(v) }
                case .integer(let v): result[column] = .number(Decimal(v))
                case .real(let v) where v.isFinite: result[column] = .number(Decimal(v))
                case .null: result[column] = .null
                default: throw SyncError.invalidRow(column)
                }
            }
            result["deleted_at"] = .null
        } else {
            // This is a delete intent; the server replaces it with its own stamp.
            result["deleted_at"] = .string("1970-01-01T00:00:00Z")
        }
        return result
    }

    static func identity(_ wire: WireRow, scope: SyncScope) throws -> String {
        guard let id = wire["sync_id"]?.string, let uuid = UUID(uuidString: id),
              wire["team_id"]?.string.flatMap(UUID.init(uuidString:)) == scope.teamID,
              wire["profile_id"]?.string.flatMap(UUID.init(uuidString:)) == scope.profileID else {
            throw SyncError.invalidRow("identity or scope")
        }
        return uuid.uuidString.lowercased()
    }

    static func cursor(_ wire: WireRow, scope: SyncScope) throws -> SyncCursor {
        let id = try identity(wire, scope: scope)
        guard let timestamp = wire["server_updated_at"]?.string, !timestamp.isEmpty else {
            throw SyncError.invalidRow("server_updated_at")
        }
        let cursor = SyncCursor(timestamp: timestamp, syncID: id)
        _ = try cursor.instant
        return cursor
    }

    static func isDeleted(_ wire: WireRow) -> Bool {
        wire["deleted_at"] != nil && wire["deleted_at"] != .null
    }

    /// The receiving database chooses its own integer id by sync_id; a sender's
    /// integer id has no meaning here. No local foreign keys exist in this table.
    static func local(wire: WireRow, localID: Int64?, scope: SyncScope, table: SyncTable = .lessons) throws -> SQLRow {
        var result: SQLRow = ["sync_id": .text(try identity(wire, scope: scope))]
        if let localID { result["id"] = .integer(localID) }
        for column in table.columns {
            let value = wire[column] ?? .null
            switch value {
            case .string(let v): result[column] = .text(v)
            case .number(let v) where table.integers.contains(column):
                guard let integer = Int64(NSDecimalNumber(decimal: v).stringValue) else { throw SyncError.invalidRow(column) }
                result[column] = .integer(integer)
            case .number(let v) where table.reals.contains(column): result[column] = .real(NSDecimalNumber(decimal: v).doubleValue)
            case .null: result[column] = .null
            default: throw SyncError.invalidRow(column)
            }
        }
        // fetchLessons lazily fills this; resolve it now so a pulled row does
        // not immediately appear as a local edit when the existing UI reads it.
        if table.name == "wizard_lessons", result["learned_id"]?.stringValue == nil {
            result["learned_id"] = .text(LearnedPreferences.stableID(result["text"]?.stringValue ?? ""))
        }
        if table.name == "wizard_lessons" {
            guard result["text"]?.stringValue != nil, result["evidence"]?.stringValue != nil,
                  let pinned = result["pinned"]?.intValue, pinned == 0 || pinned == 1 else {
                throw SyncError.invalidRow("lesson")
            }
        }
        return result
    }

    /// Restore only local file fields, matching array elements by stable identity.
    /// A teammate's path can never overwrite a path on this Mac.
    static func applyingPortableJSON(_ remote: SyncJSON, to local: SyncJSON?) -> SyncJSON {
        switch remote {
        case .object(var fields):
            guard case .object(let previous) = local else { return remote }
            for (key, value) in previous where isLocalField(key) { fields[key] = value }
            for key in fields.keys where !isLocalField(key) {
                fields[key] = applyingPortableJSON(fields[key] ?? .null, to: previous[key])
            }
            return .object(fields)
        case .array(let values):
            guard case .array(let previous) = local else { return remote }
            return .array(values.map { value in
                guard case .object(let fields) = value,
                      let key = ["id", "key", "name"].first(where: { fields[$0] != nil }) else { return value }
                let old = previous.first {
                    guard case .object(let item) = $0 else { return false }
                    return item[key] == fields[key]
                }
                return applyingPortableJSON(value, to: old)
            })
        default: return remote
        }
    }

    static func portableJSONString(_ value: SyncJSON) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(portableJSON(value)), as: UTF8.self)
    }

    static func isLocalField(_ key: String) -> Bool {
        let key = key.lowercased()
        return key == "path" || key.hasSuffix("path") || key == "fontfile" || key == "exemplar_frames"
    }

    static func portableJSON(_ value: SyncJSON) -> SyncJSON {
        switch value {
        case .object(let fields):
            return .object(fields.filter { !isLocalField($0.key) }.mapValues(portableJSON))
        case .array(let values): return .array(values.map(portableJSON))
        default: return value
        }
    }

    /// Canonical natural-key identities also converge simultaneous first uploads.
    static func stableID(_ components: [String]) -> String {
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [String(hex.prefix(8)), String(hex.dropFirst(8).prefix(4)), String(hex.dropFirst(12).prefix(4)),
                String(hex.dropFirst(16).prefix(4)), String(hex.suffix(12))].joined(separator: "-")
    }
}
