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
