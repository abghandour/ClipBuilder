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
    @Test func restoreUndoesDismiss() async throws {
        let temp = try TempDirectory()
        let database = try Database(path: temp.url.appendingPathComponent("profile.db"))
        try await database.addLesson(text: "Rule", pinned: false, evidence: "Reviews")
        let id = try #require(try await database.fetchLessons().first?.learnedID)
        var profile = BrandProfile(name: "Test")
        profile = try await LearnedEditing.editLesson(id, action: .dismiss, profile: profile, database: database)
        #expect(profile.learnedSharing.dismissedLessons.contains(id))
        profile = LearnedEditing.restoreLesson(id, profile: profile)
        #expect(!profile.learnedSharing.dismissedLessons.contains(id))
        let build = try await LearnedDocumentBuilder.build(profile: profile, database: database)
        #expect(build.document.sections.first { $0.kind == .lessons }?.items.count == 1)
        #expect(LearnedEditing.restoreLesson("missing", profile: profile) == profile)
    }
    @Test func editCategoryKeepsIdentity() {
        var profile = BrandProfile(name: "Test")
        profile.tasteCategories = [.init(key: "fight", label: "Fight", rubric: "Old", exemplarFrames: ["a.jpg"], studiedCount: 3)]
        let edited = LearnedEditing.editCategory("fight", label: " Fights ", rubric: "New rubric\n", profile: profile)
        let category = edited.tasteCategories[0]
        #expect(category.key == "fight")
        #expect(category.label == "Fights")
        #expect(category.rubric == "New rubric")
        #expect(category.exemplarFrames == ["a.jpg"])
        #expect(category.studiedCount == 3)
        #expect(edited.learnedSharing.updatedAt["taste"] != nil)
        #expect(LearnedEditing.editCategory("fight", label: "", rubric: "x", profile: profile).tasteCategories[0].label == "Fight")
    }
}

struct LearnedEditingDeltaTests {
    @Test func deltaNeverRestoresStaleDismissals() {
        var current = BrandProfile(name: "Test")
        current.learnedSharing.dismissedLessons = []  // user restored "b" meanwhile
        var edited = BrandProfile(name: "Test")
        edited.learnedSharing.dismissedLessons = ["b"]  // stale snapshot the edit started from
        edited.learnedSharing.updatedAt["lessons"] = Date(timeIntervalSince1970: 5)
        let pinned = LearnedEditing.applyDelta(.pin(true), id: "a", from: edited, to: current)
        #expect(pinned.learnedSharing.dismissedLessons.isEmpty)
        #expect(pinned.learnedSharing.updatedAt["lessons"] == Date(timeIntervalSince1970: 5))
        let dismissed = LearnedEditing.applyDelta(.dismiss, id: "a", from: edited, to: current)
        #expect(dismissed.learnedSharing.dismissedLessons == ["a"])
    }
}

struct LearnedOnboardingTests {
    @Test func predicatesIgnoreDefaultsAndDismissed() {
        var profile = BrandProfile(name: "Test")
        let empty = LearnedOnboarding.make(profile: profile, lessons: [], people: [], reviews: 0, benchmarks: nil)
        #expect(empty.isEmpty)
        profile.houseStyle = " "
        profile.tasteRubric = "Keepers"
        profile.learnedSharing.dismissedLessons = ["hidden"]
        let hidden = WizardLesson(learnedID: "hidden", id: 1, text: "Hidden", pinned: false, evidence: "")
        let partial = LearnedOnboarding.make(profile: profile, lessons: [hidden], people: [], reviews: 2, benchmarks: nil)
        #expect(partial.done == [.tasteRubric, .reviews])
        #expect(partial.reviewCount == 2)
        #expect(partial.completed == 2 && partial.total == 6)
        let shown = WizardLesson(learnedID: "shown", id: 2, text: "Shown", pinned: false, evidence: "")
        let more = LearnedOnboarding.make(profile: profile, lessons: [hidden, shown], people: [], reviews: 2, benchmarks: nil)
        #expect(more.done.contains(.rules))
    }
}
