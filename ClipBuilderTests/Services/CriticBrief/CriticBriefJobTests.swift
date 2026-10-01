import Foundation
import Testing
@testable import Clip_Builder

@MainActor
struct CriticBriefJobTests {
    @Test func refreshIsAnApplyOnFinishWizardJobAndDeduplicatesProfile() async throws {
        let jobs = AppJobs()
        var started = 0
        let first = jobs.start(.criticBrief, title: "Critic Brief", project: nil,
                               profileGeneration: 0, subjectID: "profile") { log in
            started += 1
            log("Critic brief refreshed: 6 exemplars")
            return nil
        }
        let duplicate = jobs.start(.criticBrief, title: "Critic Brief", project: nil,
                                   profileGeneration: 0, subjectID: "profile") { _ in
            started += 1
            return nil
        }
        #expect(first == duplicate)
        #expect(AppJobKind.criticBrief.channel == "wizard" && AppJobKind.criticBrief.postsNotice)
        #expect(AppJobKind.evaluateCritic.channel == "wizard")
        for _ in 0..<200 where jobs.hasLiveTasks { try await Task.sleep(for: .milliseconds(5)) }
        #expect(started == 1 && !jobs.hasLiveTasks)
        #expect(jobs.reviewQueue.isEmpty)
        #expect(jobs.latest(.criticBrief)?.statusLine == "Critic brief refreshed: 6 exemplars")
    }
}
