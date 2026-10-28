import Foundation
import Testing
@testable import Clip_Builder

@Suite("Screen crop roles")
struct ScreenCropStoreTests {
    @Test func rolesRoundTripAndOldFilesRemainReadable() throws {
        let data = Data(#"{"areas":[{"name":"Old","points":[{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1}]}]}"#.utf8)
        let old = try JSONDecoder().decode(ScreenCropLayout.self, from: data)
        #expect(old.areas.first?.role == nil)
        for role in ScreenCropArea.Role.allCases {
            var area = try #require(old.areas.first)
            area.role = role
            #expect(try JSONDecoder().decode(ScreenCropArea.self, from: JSONEncoder().encode(area)) == area)
        }
    }

    @Test func allFourRoleLayoutsShipInLayerOrder() throws {
        let expected: [(String, [ScreenCropArea.Role])] = [
            ("Split", [.vip, .others]), ("PiP", [.others, .vip]),
            ("Three stack", [.vip, .others, .broll]), ("Screen + presenter", [.screen, .presenter])]
        for (name, roles) in expected {
            let layout = try #require(ScreenCropStore.builtIn.first { $0.name == name })
            #expect(layout.areas.compactMap(\.role) == roles)
            #expect(layout.areasInTrackOrder == layout.areas)
        }
        let pip = try #require(ScreenCropStore.builtIn.first { $0.name == "PiP" })
        #expect(pip.areas[0].coverage == 1)
        #expect(pip.areas[1].coverage < 0.2)
        let stack = try #require(ScreenCropStore.builtIn.first { $0.name == "Three stack" })
        #expect(stack.areas.allSatisfy { abs($0.bounds.h - 1.0 / 3) < 0.001 })
        // Legacy references remain valid.
        #expect(ScreenCropStore.builtIn.contains { $0.name == "50-50 Horizontal" })
    }
}
