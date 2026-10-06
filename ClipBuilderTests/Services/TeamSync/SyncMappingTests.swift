import Foundation
import Testing
@testable import Clip_Builder

struct SyncMappingTests {
    @Test("Lesson wire format remaps integer ids and excludes paths while retaining future fields")
    func roundTrip() throws {
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let syncID = UUID().uuidString.lowercased()
        let local: SQLRow = ["id": .integer(41), "sync_id": .text(syncID), "text": .text("Keep the hook short"),
                             "pinned": .integer(1), "evidence": .text("Review"), "provider": .text("test"),
                             "model": .null, "learned_id": .text("stable-lesson"), "created_at": .text("2026-10-06 00:00:00"),
                             "updated_at": .null, "path": .text("/private/secret.mov"), "thumbnail_path": .text("/local/a.png")]
        let future: SyncJSON = .object(["flags": .array([.bool(true), .null]), "weight": .number(Decimal(string: "12345678901234567890.123")!)])
        let wire = try SyncMapping.wire(local: local, syncID: syncID, scope: scope, preserved: ["future": future])
        let decoded = try JSONDecoder().decode(SyncMapping.WireRow.self, from: JSONEncoder().encode(wire))
        let received = try SyncMapping.local(wire: decoded, localID: 999, scope: scope)
        #expect(received["id"]?.intValue == 999)
        #expect(received["sync_id"]?.stringValue == syncID)
        #expect(received["text"]?.stringValue == local["text"]?.stringValue)
        #expect(received["pinned"]?.intValue == 1)
        #expect(wire["id"] == nil)
        #expect(wire["path"] == nil)
        #expect(wire["thumbnail_path"] == nil)
        let again = try SyncMapping.wire(local: received, syncID: syncID, scope: scope, preserved: decoded)
        #expect(again == wire)
        #expect(again["future"] == future)
    }

    @Test("Cursors compare instants and preserve microseconds across timestamp spellings")
    func cursorOrdering() throws {
        let a = SyncCursor(timestamp: "2026-10-06T00:00:00.000001Z", syncID: "a")
        let b = SyncCursor(timestamp: "2026-10-06T00:00:00.000002+00:00", syncID: "a")
        #expect(try b.isAfter(a))
        let same = SyncCursor(timestamp: "2026-10-06T00:00:00.000002Z", syncID: "b")
        #expect(try same.isAfter(b))
        #expect(throws: SyncError.self) {
            try SyncCursor(timestamp: "invalid", syncID: "a").instant
        }
    }

    @Test("Rows from another team or profile are refused")
    func scopeValidation() throws {
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let wire = try SyncMapping.wire(local: nil, syncID: UUID().uuidString, scope: scope)
        #expect(throws: SyncError.self) {
            try SyncMapping.identity(wire, scope: SyncScope(teamID: UUID(), profileID: scope.profileID))
        }
        #expect(throws: SyncError.self) {
            try SyncMapping.identity(wire, scope: SyncScope(teamID: scope.teamID, profileID: UUID()))
        }
    }
}

extension SyncMappingTests {
    @Test("Every Phase 1 projection preserves portable values and strips local paths", arguments: SyncTable.all)
    func everyTable(table: SyncTable) throws {
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        var local: SQLRow = [:]
        for column in table.columns {
            if table.references[column] != nil { local[column] = .text(UUID().uuidString.lowercased()) }
            else if table.integers.contains(column) { local[column] = .integer(column == "pinned" ? 1 : 42) }
            else if table.reals.contains(column) { local[column] = .real(12.75) }
            else { local[column] = .text(column.hasSuffix("_json") ? "{}" : "portable-\(column)") }
        }
        local["path"] = .text("/private/mac-only.mov")
        local["thumbnail_path"] = .text("/private/thumbnail.jpg")
        let identity = table.name == "profile_documents" ? scope.profileID.uuidString : UUID().uuidString
        let wire = try SyncMapping.wire(local: local, syncID: identity, scope: scope,
                                       preserved: ["future_field": .object(["enabled": .bool(true)])], table: table)
        let decoded = try JSONDecoder().decode(SyncMapping.WireRow.self, from: JSONEncoder().encode(wire))
        let received = try SyncMapping.local(wire: decoded, localID: nil, scope: scope, table: table)
        for column in table.columns {
            #expect(received[column]?.stringValue == local[column]?.stringValue, "\(table.name).\(column)")
        }
        #expect(wire["path"] == nil)
        #expect(wire["thumbnail_path"] == nil)
        #expect(try SyncMapping.wire(local: received, syncID: identity, scope: scope, preserved: decoded, table: table) == wire)
    }

    @Test("Shared profile JSON excludes machine configuration and preserves local exemplar files on apply")
    func profileDocument() throws {
        var profile = BrandProfile(name: "Local")
        profile.profileID = UUID()
        profile.teamID = UUID()
        profile.logoPath = "/private/logo.png"
        profile.sourceFolder = "/private/footage"
        profile.houseStyle = "Keep the opening short"
        profile.tasteCategories = [TasteCategory(key: "fight", label: "Fights", exemplarFrames: ["/private/frame.jpg"])]
        let json = try TeamProfileDocument.encode(profile)
        #expect(!json.contains("/private"))
        #expect(!json.contains("team_id"))
        var receiver = profile
        receiver.sourceFolder = "/private/receiver"
        receiver.houseStyle = "Old"
        let applied = try TeamProfileDocument.applying(json, to: receiver)
        #expect(applied.houseStyle == profile.houseStyle)
        #expect(applied.sourceFolder == receiver.sourceFolder)
        #expect(applied.tasteCategories[0].exemplarFrames == receiver.tasteCategories[0].exemplarFrames)
    }
}

extension SyncMappingTests {
    @Test("Asset identity resolves aliases, known moved roots, and never falls back to the basename")
    func assetIdentityPaths() throws {
        let root = URL(fileURLWithPath: "/private/tmp/SyncAssets-\(UUID().uuidString)")
        let alias = root.appendingPathExtension("alias")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: root)
        }
        let actual = TeamSyncAsset.identity(path: root.appendingPathComponent("a/IMG_0001.jpg").path, kind: "images", knownRoots: [root])
        #expect(actual == TeamSyncAsset.identity(path: alias.appendingPathComponent("a/IMG_0001.jpg").path, kind: "images", knownRoots: [root]))
        let moved = URL(fileURLWithPath: "/private/tmp/old-library")
        #expect(actual == TeamSyncAsset.identity(path: moved.appendingPathComponent("a/IMG_0001.jpg").path, kind: "images", knownRoots: [root, moved]))
        #expect(TeamSyncAsset.identity(path: "/unknown/a/IMG_0001.jpg", kind: "images") != TeamSyncAsset.identity(path: "/unknown/b/IMG_0001.jpg", kind: "images"))
    }
}
