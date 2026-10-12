import Foundation
import Testing
@testable import Clip_Builder

struct ActiveLayerSyncTests {
    @Test func pinRoundTripRetainsAbsentTargetAndReservedTranscriptionKey() throws {
        let table = try #require(SyncTable.all.first { $0.name == "videos" })
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let syncID = UUID().uuidString.lowercased()
        let local: SQLRow = ["hash": .text("fixture"), "filename": .text("fixture.mp4"),
                             "active_run_key": .text("run-not-on-this-mac"), "active_transcription_key": .text("reserved-set")]
        let wire = try SyncMapping.wire(local: local, syncID: syncID, scope: scope, table: table)
        let decoded = try JSONDecoder().decode(SyncMapping.WireRow.self, from: JSONEncoder().encode(wire))
        let received = try SyncMapping.local(wire: decoded, localID: 42, scope: scope, table: table)
        #expect(received["active_run_key"]?.stringValue == "run-not-on-this-mac")
        #expect(received["active_transcription_key"]?.stringValue == "reserved-set")
        #expect(table.references["active_run_key"] == nil)
        let unpinned = try SyncMapping.wire(local: ["hash": .text("fixture"), "active_run_key": .null],
                                           syncID: syncID, scope: scope, preserved: decoded, table: table)
        let unpinnedLocal = try SyncMapping.local(wire: unpinned, localID: 42, scope: scope, table: table)
        #expect(unpinnedLocal["active_run_key"]?.stringValue == nil)
    }
}
