import Foundation

extension AppStore {
    func retryFightScoring(video: VideoRecord, scope: FightCorrections.RetryScope) {
        guard let database, !fightScoringInFlight.contains(video.id) else { return }
        let generation = self.profileGeneration
        let profile = self.activeProfile
        self.fightRetryResults[video.id] = nil
        self.fightScoringJobsInFlight.insert(video.id)
        self.jobs.start(.fightScore, title: "Retry fight — \(video.filename)", project: self.activeProject,
            profileGeneration: generation, subjectID: String(video.id), cleanup: { [weak self] in
                guard let self, self.profileGeneration == generation else { return }
                self.fightScoringJobsInFlight.remove(video.id)
                self.continueAnalysisStepBatch()
            }) { [self] jobLog in
                let fileLog = self.logSink(\.analysisLog)
                let log: @Sendable (String) -> Void = { line in jobLog(line); fileLog(line) }
                do {
                    let before = try await database.fetchFightEvents(videoID: video.id)
                    _ = try await self.analyzer.scoreFightAction(video: video, profile: profile, database: database,
                        retryScope: scope, log: log)
                    let after = try await database.fetchFightEvents(videoID: video.id)
                    let passes = try await database.fetchAnalysisPasses()
                    guard generation == self.profileGeneration, self.database === database else { return nil }
                    self.fightEvents[video.id] = after
                    self.analysisPasses = passes
                    var result = await Task.detached {
                        FightCorrections.difference(before: before, after: after).summary
                    }.value
                    let pass = passes.last { $0.videoID == video.id && $0.pass == .fightScore }
                    if pass?.status == .failed {
                        result += " · Some stretches failed; their earlier actions were kept"
                        ErrorLog.record("Fight Action retry", result)
                    }
                    guard generation == self.profileGeneration, self.database === database else { return nil }
                    self.fightRetryResults[video.id] = result
                    // Learning is best effort, after scoring has committed. It never
                    // turns a completed retry into a failed job.
                    if let count = await FightScoringLearning.update(database: database, ai: self.ai, log: log) {
                        result += " · \(count) lessons updated"
                    }
                    guard generation == self.profileGeneration, self.database === database else { return nil }
                    self.fightRetryResults[video.id] = result
                    self.fightLessonsRevision += 1
                    log(result)
                    return nil
                } catch {
                    ErrorLog.record("Fight Action retry", error.localizedDescription)
                    if generation == self.profileGeneration, self.database === database {
                        self.fightRetryResults[video.id] = error is CancellationError ? "Retry stopped" : error.localizedDescription
                        let passes = try? await database.fetchAnalysisPasses()
                        if generation == self.profileGeneration, self.database === database, let passes {
                            self.analysisPasses = passes
                        }
                    }
                    throw error
                }
            }
    }
}
