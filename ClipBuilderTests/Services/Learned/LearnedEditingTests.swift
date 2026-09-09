import Foundation
import Testing
@testable import Clip_Builder

struct LearnedEditingTests {
    @Test func dismissKeepsRowAndRewriteKeepsIdentity() async throws {
        let temp = try TempDirectory()
        let database = try Database(path: temp.url.appendingPathComponent("profile.db"))
        try await database.addLesson(text: "Rule", pinned: false, evidence: "Reviews")
        let id = try #require(try await database.fetchLessons().first?.learnedID)
        var profile = BrandProfile(name: "Test")
        profile = try await LearnedEditing.editLesson(id, action: .pin(true), profile: profile, database: database)
        profile = try await LearnedEditing.editLesson(id, action: .rewrite("Better rule"), profile: profile, database: database)
        profile = try await LearnedEditing.editLesson(id, action: .dismiss, profile: profile, database: database)
        let rows = try await database.fetchLessons()
        #expect(rows.count == 1)
        #expect(rows.first?.pinned == true)
        #expect(rows.first?.text == "Better rule")
        #expect(rows.first?.learnedID == id)
        let build = try await LearnedDocumentBuilder.build(profile: profile, database: database)
        #expect(build.document.sections.first { $0.kind == .lessons }?.items.isEmpty == true)
    }
    @Test func dropEditsLocalCategory() {
        var profile = BrandProfile(name: "Test")
        profile.tasteCategories = [.init(key: "fight", label: "Fight"), .init(key: "interview", label: "Interview")]
        let edited = LearnedEditing.dropCategory("fight", profile: profile)
        #expect(edited.tasteCategories.map(\.key) == ["interview"])
        #expect(edited.learnedSharing.updatedAt["taste"] != nil)
    }
}
