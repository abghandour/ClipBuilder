import Testing
@testable import Clip_Builder

@MainActor struct LearnedPreferencesViewTests {
    @Test func reachableFromProfileWideSidebar() {
        #expect(SidebarSection.visibleSections.contains(.learned))
        #expect(SidebarSection.learned.projectDestination == .learned)
        #expect(!SidebarSection.projectSections.contains(.learned))
        #expect(SidebarSection.resourceSections.last == .learned)
        #expect(SidebarSection.learned.title == "AI Lessons")
    }
}
