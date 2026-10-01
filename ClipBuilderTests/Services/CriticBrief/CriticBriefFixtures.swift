import Foundation
@testable import Clip_Builder

nonisolated enum CriticBriefFixtures {
    static func brief() -> CriticBrief {
        CriticBrief(key: "test-key", builtAt: Date(timeIntervalSince1970: 100),
            rules: "HOOK: Start with action.\nDO NOT REWARD: Decorative text.",
            exemplars: [
                .init(id: "generated:1", label: "REFERENCE A", why: "starred", duration: 24,
                      traits: nil, sheetPath: "sheet-0.jpg"),
                .init(id: "reference:2", label: "REFERENCE B", why: "studied account", duration: 20,
                      traits: nil, sheetPath: "sheet-1.jpg")], provider: "fixture", model: "fixture")
    }
}
