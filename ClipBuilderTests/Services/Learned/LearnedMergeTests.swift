import Foundation
import Testing
@testable import Clip_Builder

struct LearnedMergeTests {
    func document(_ name: String, text: String, date: Double, field: String = "lesson", pinned: Bool = false) -> LearnedPreferences {
        .init(contributor: name, sections: [.init(kind: field == "lesson" ? .lessons : .style, enabled: true,
            updatedAt: Date(timeIntervalSince1970: date), evidence: "Two reviews", items: [
                .init(id: "stable", field: field, text: text, pinned: pinned, updatedAt: Date(timeIntervalSince1970: date))])])
    }
    @Test func unionNewestSingleLocalMuteAndOrigins() throws {
        let local = document("Local", text: "Old", date: 1)
        let remote = document("Studio", text: "New", date: 2)
        let merged = LearnedMerge.merge(local: local, contributors: [remote])
        #expect(merged.count == 1)
        #expect(merged.first?.item.text == "New")
        #expect(merged.first?.text.hasPrefix("[Studio]") == true)
        #expect(LearnedMerge.merge(local: local, contributors: [remote], muted: ["Studio"]).first?.item.text == "Old")
        let localStyle = document("Local", text: "Local style", date: 1, field: "houseStyle")
        let remoteStyle = document("Studio", text: "Remote style", date: 2, field: "houseStyle")
        #expect(LearnedMerge.merge(local: localStyle, contributors: [remoteStyle]).first?.item.text == "Local style")
    }
    @Test func capPrioritizesPinnedThenLocal() {
        let local = document("Local", text: "Local", date: 1)
        var remote = document("Studio", text: "Pinned", date: 2, pinned: true)
        remote.sections[0].items[0].id = "pinned"
        var extra = document("Other", text: String(repeating: "Long", count: 100), date: 3)
        extra.sections[0].items[0].id = "extra"
        let lines = LearnedMerge.merge(local: local, contributors: [remote, extra], characterLimit: 200)
        #expect(lines.map(\.origin) == ["Studio", "Local"])
        #expect(lines.allSatisfy { $0.text.contains("[\($0.origin)]") })
    }
}
