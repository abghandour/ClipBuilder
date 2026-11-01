import Foundation
import Testing
@testable import Clip_Builder

@Suite("Projects and AI Lessons assistants")
struct ProjectsAssistantTests {
    private func project(_ id: Int64, _ name: String, opened: String?, archived: Bool = false,
                         home: Bool = false) -> ProjectRecord {
        ProjectRecord(id: id, profileName: "test", name: name, lastOpenedAt: opened, archived: archived, isHome: home,
                      sourceCount: 0, timelineCount: 0, outputCount: 0, thumbnailPaths: [])
    }

    private func projectIDs(_ s: ProjectsAssistant.Snapshot) -> [String] {
        ProjectsAssistant().suggestions(for: ProjectsAssistant.context(s)).map(\.id)
    }

    @Test func noProjectsSuggestsCreatingOne() {
        let rows = ProjectsAssistant().suggestions(for: ProjectsAssistant.context(.init(homeSources: 4, tasteSet: true, month: "2026-11")))
        #expect(rows.map(\.id) == ["projects.new.none"])
        #expect(rows.first?.reason == "4 sources in Home and no project to group them")
    }

    @Test func activeProjectsSuggestTheLastOneAndTheMonthlyGapsReport() {
        let rows = ProjectsAssistant().suggestions(for: ProjectsAssistant.context(
            .init(active: 2, recentID: 7, recentName: "UFC 310", tasteSet: true, month: "2026-11")))
        #expect(rows.map(\.id) == ["projects.open.p7", "projects.gaps.2026-11"])
        #expect(rows.map(\.actionID) == ["projects.open.recent", "projects.gaps"])
    }

    @Test func missingTasteSuggestsTheStartingStyle() {
        #expect(projectIDs(.init(month: "2026-11")).contains("projects.starter.missing"))
        #expect(!projectIDs(.init(tasteSet: true, month: "2026-11")).contains("projects.starter.missing"))
    }

    @Test func mostRecentSkipsHomeAndArchived() {
        let projects = [project(1, "Home", opened: "2026-10-30 10:00:00", home: true),
                        project(2, "Old", opened: "2026-10-01 10:00:00"),
                        project(3, "Archived", opened: "2026-10-29 10:00:00", archived: true),
                        project(4, "Recent", opened: "2026-10-20 10:00:00")]
        #expect(ProjectsAssistant.mostRecent(projects)?.name == "Recent")
        #expect(ProjectsAssistant.mostRecent([projects[0]]) == nil)
    }

    @Test func monthKey() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9))!
        #expect(ProjectsAssistant.month(date, calendar: calendar) == "2026-03")
    }

    @Test func projectsRouting() {
        #expect(ProjectsAssistant.route("Open the project I worked on last") == "projects.open.recent")
        #expect(ProjectsAssistant.route("Create a new project") == "projects.new")
        #expect(ProjectsAssistant.route("What should I post next?") == "projects.gaps")
        #expect(ProjectsAssistant.route("generate a starting style") == "projects.starter")
        #expect(ProjectsAssistant.route("hello") == nil)
    }

    // MARK: AI Lessons

    private func lessonIDs(_ s: LessonsAssistant.Snapshot) -> [String] {
        LessonsAssistant().suggestions(for: LessonsAssistant.context(s)).map(\.id)
    }

    @Test func lessonsQuietWhenDistilledAndComplete() {
        #expect(lessonIDs(.init(lessons: 4, pinned: 1, reviews: 9, onboardingDone: 6, onboardingTotal: 6)).isEmpty)
    }

    @Test func reviewsWithoutDistilledRulesSuggestDistilling() {
        #expect(lessonIDs(.init(lessons: 2, pinned: 2, reviews: 5)) == ["lessons.distill.undistilled"])
        #expect(lessonIDs(.init(lessons: 2, pinned: 2, reviews: 4)).isEmpty)
        #expect(lessonIDs(.init(lessons: 2, pinned: 2, reviews: 5, distilling: true)).isEmpty)
    }

    @Test func noTeamDocumentsSuggestPublishing() {
        #expect(lessonIDs(.init(lessons: 3, pinned: 0, reviews: 1, hasHome: true, hasNickname: true)) == ["lessons.publish.none"])
        #expect(lessonIDs(.init(lessons: 3, reviews: 1, hasHome: true, hasNickname: false)).isEmpty)
        #expect(lessonIDs(.init(lessons: 3, reviews: 1, hasHome: true, hasNickname: true, contributors: 1)).isEmpty)
    }

    @Test func incompleteOnboardingIsAnInsight() {
        let rows = LessonsAssistant().suggestions(for: LessonsAssistant.context(.init(lessons: 1, onboardingDone: 2, onboardingTotal: 6)))
        #expect(rows.map(\.id) == ["lessons.onboarding.incomplete"])
        #expect(rows.first?.kind == .insight)
        #expect(rows.first?.actionID == nil)
    }

    @Test func lessonsRouting() {
        #expect(LessonsAssistant.route("Distill rules from my reviews") == "lessons.distill")
        #expect(LessonsAssistant.route("Publish my lessons to the team") == "lessons.publish")
        #expect(LessonsAssistant.route("What should I post next?") == "lessons.gaps")
        #expect(LessonsAssistant.route("hello") == nil)
    }
}
