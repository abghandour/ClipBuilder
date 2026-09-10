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
    @Test func reportExplainsEveryExclusion() {
        let local = document("Local", text: "Old", date: 1)
        let newer = document("Studio", text: "New", date: 2)
        let older = document("Attic", text: "Older", date: 0)
        var quiet = document("Quiet", text: "Muted", date: 5)
        quiet.sections[0].items[0].id = "quiet"
        var unshared = document("Private", text: "Hidden", date: 5)
        unshared.sections[0].enabled = false
        unshared.sections[0].items[0].id = "hidden"
        var blank = document("Blank", text: "", date: 5)
        blank.sections[0].items[0].id = "blank"
        let report = LearnedMerge.mergeReport(local: local, contributors: [newer, older, quiet, unshared, blank], muted: ["Quiet"])
        #expect(report.winners.map(\.origin) == ["Studio"])
        #expect(report.winners == LearnedMerge.merge(local: local, contributors: [newer, older, quiet, unshared, blank], muted: ["Quiet"]))
        let reasons = Dictionary(uniqueKeysWithValues: report.excluded.map { ($0.line.origin, $0.reason) })
        #expect(reasons["Local"] == .olderThanWinner)
        #expect(reasons["Attic"] == .olderThanWinner)
        #expect(reasons["Quiet"] == .contributorMuted)
        #expect(reasons["Private"] == .sectionNotShared)
        #expect(reasons["Blank"] == .empty)
        let localStyle = document("Local", text: "Local style", date: 1, field: "houseStyle")
        let remoteStyle = document("Studio", text: "Remote style", date: 2, field: "houseStyle")
        let styles = LearnedMerge.mergeReport(local: localStyle, contributors: [remoteStyle])
        #expect(styles.excluded.first?.reason == .overriddenByLocal)
        var long = document("Other", text: String(repeating: "Long", count: 100), date: 3)
        long.sections[0].items[0].id = "long"
        let budget = LearnedMerge.mergeReport(local: local, contributors: [long], characterLimit: 60)
        #expect(budget.excluded.contains { $0.line.origin == "Other" && $0.reason == .overBudget })
    }
    /// Golden output pinned before mergeReport existed: order, origins, and
    /// texts must not move when the merge is refactored.
    @Test func goldenOrderAndText() {
        let local = LearnedPreferences(contributor: "Local", sections: [
            .init(kind: .lessons, enabled: true, updatedAt: Date(timeIntervalSince1970: 10), evidence: "Two reviews", items: [
                .init(id: "l1", field: "lesson", text: "Local rule", updatedAt: Date(timeIntervalSince1970: 10)),
                .init(id: "shared", field: "lesson", text: "Old shared", updatedAt: Date(timeIntervalSince1970: 1)),
            ]),
            .init(kind: .style, enabled: true, updatedAt: Date(timeIntervalSince1970: 3), evidence: "Profile", items: [
                .init(id: "houseStyle", field: "houseStyle", text: "Mine", updatedAt: Date(timeIntervalSince1970: 3)),
            ]),
        ])
        let studio = LearnedPreferences(contributor: "Studio", sections: [
            .init(kind: .lessons, enabled: true, updatedAt: Date(timeIntervalSince1970: 20), evidence: "Ten reviews", items: [
                .init(id: "shared", field: "lesson", text: "New shared", pinned: true, updatedAt: Date(timeIntervalSince1970: 20)),
                .init(id: "s2", field: "lesson", text: "Studio only", updatedAt: Date(timeIntervalSince1970: 15)),
            ]),
            .init(kind: .style, enabled: true, updatedAt: Date(timeIntervalSince1970: 30), evidence: "Profile", items: [
                .init(id: "houseStyle", field: "houseStyle", text: "Theirs", updatedAt: Date(timeIntervalSince1970: 30)),
            ]),
        ])
        let lines = LearnedMerge.merge(local: local, contributors: [studio])
        #expect(lines.map(\.text) == [
            "[Studio] Lesson: New shared [evidence: Ten reviews]",
            "[Local] Lesson: Local rule [evidence: Two reviews]",
            "[Local] House style: Mine [evidence: Profile]",
            "[Studio] Lesson: Studio only [evidence: Ten reviews]",
        ])
        #expect(LearnedMerge.contributorBlock(lines) == "\n\n## SHARED LEARNING\n[Studio] Lesson: New shared [evidence: Ten reviews]\n[Studio] Lesson: Studio only [evidence: Ten reviews]")
    }
}
