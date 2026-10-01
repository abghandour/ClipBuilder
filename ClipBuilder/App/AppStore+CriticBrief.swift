import Foundation

extension AppStore {
    func startCriticBriefRefresh() {
        guard let database else { return }
        let profile = activeProfile
        let generation = profileGeneration
        let briefStore = CriticBriefStore(profile: profile)
        jobs.start(.criticBrief, title: "Critic Brief", project: nil,
                   profileGeneration: generation, subjectID: profile.profileName) { [self] log in
            let selection = try await CriticExemplars.select(database: database, profile: profile, emit: log)
            guard selection.reason == nil else {
                throw AppJobEmptyResult(message: selection.reason ?? "No exemplars available.")
            }
            guard let brief = try await briefStore.build(pool: selection.exemplars, profile: profile, ai: ai, emit: log) else {
                throw AppJobEmptyResult(message: "Star 2 generated reels or import reference reels first.")
            }
            try Task.checkCancellation()
            guard generation == profileGeneration else { throw CancellationError() }
            log("Critic brief refreshed: \(brief.exemplars.count) exemplars")
            return nil
        }
    }

    func criticBriefState() async -> String {
        guard let database else { return "No brief: open a profile first" }
        let profile = activeProfile
        do {
            let selection = try await CriticExemplars.select(database: database, profile: profile)
            return try await AppJobWork.run {
                let briefStore = CriticBriefStore(profile: profile)
                let passed = briefStore.load().map { briefStore.enabledByDefault($0) } ?? false
                let usage = profile.criticBriefUse.status(keepRulePassed: passed)
                return "\(usage) · \(briefStore.state(pool: selection.exemplars, profile: profile))"
            }
        } catch { return "Critic brief unavailable: \(error.userMessage)" }
    }
}

extension AppStore {
    func startCriticEvaluation() {
        guard let database else { return }
        let profile = activeProfile
        let benchmarks = igBenchmarks
        jobs.start(.evaluateCritic, title: "Evaluate Critic", project: nil,
                   profileGeneration: profileGeneration, subjectID: profile.profileName) { [self] log in
            let report = try await CriticEvaluator.evaluate(database: database, profile: profile,
                                                           ai: ai, benchmarks: benchmarks, emit: log)
            log(report.summary)
            return nil
        }
    }
}
