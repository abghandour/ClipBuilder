import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppStore {
    // MARK: - Fight research

    /// Best-effort fight identity for the confirm sheet: named people on the
    /// video, the extracted outcome, and the filename.
    func guessFightIdentity(video: VideoRecord) async -> FightResearchService.Identity {
        guard let database else { return FightResearchService.Identity() }
        let keys = ((try? await database.fetchVideoPeople(videoID: video.id)) ?? []).map(\.key)
        let outcomes = ((try? await database.fetchOutcomes()) ?? [])
            .filter { $0.videoID == video.id }
        return FightResearchService.guessIdentity(video: video, people: people,
                                                  videoPersonKeys: keys, outcomes: outcomes)
    }

    /// Run (or re-run) the crawl + summarize for one video, then refresh the
    /// cached dictionary. Throws with actionable messages.
    func runFightResearch(video: VideoRecord, identity: FightResearchService.Identity,
                          log: @escaping @Sendable (String) -> Void) async throws -> FightResearchRecord {
        guard let database else {
            throw AIError.notConfigured("No profile database is open")
        }
        guard !fightResearchInFlight.contains(video.id) else {
            throw AIError.notConfigured("Research is already running for this video")
        }
        let generation = profileGeneration
        let projectID = activeProjectID
        fightResearchInFlight.insert(video.id)
        defer { fightResearchInFlight.remove(video.id) }
        let record = try await fightResearchService.run(video: video, identity: identity,
                                                        profile: activeProfile,
                                                        database: database, emit: log,
                                                        useLocal: OnDevicePolicy.isEnabled(item: "fight-queries", config: settings.ai))
        try Task.checkCancellation()
        guard generation == profileGeneration else { throw CancellationError() }
        if projectID == activeProjectID { fightResearch[video.id] = record }
        return record
    }

    /// Column-level refresh: re-crawl with the saved identity, logging into
    /// the analysis log panel.
    func refreshFightResearch(video: VideoRecord) {
        guard let existing = fightResearch[video.id],
              !fightResearchInFlight.contains(video.id) else { return }
        let identity = FightResearchService.Identity(fighters: existing.fightLabel,
                                                     event: existing.event,
                                                     date: existing.fightDate)
        Task {
            do {
                let sink = logSink(\.analysisLog)
                _ = try await runFightResearch(video: video, identity: identity) { message in
                    sink("Fight research: \(message)")
                }
            } catch {
                presentError("Fight research failed for \(video.filename)", error)
            }
        }
    }

    /// User edits from the research sheet — identity + story only; the
    /// crawled sources and timestamp stay.
    func saveFightResearchEdits(videoID: Int64, fightLabel: String, event: String,
                                fightDate: String, summaryJSON: String) {
        guard let database else { return }
        Task {
            do {
                try await database.updateFightResearch(videoID: videoID, fightLabel: fightLabel,
                                                       event: event, fightDate: fightDate,
                                                       summaryJSON: summaryJSON)
                if var record = fightResearch[videoID] {
                    record.fightLabel = fightLabel
                    record.event = event
                    record.fightDate = fightDate
                    record.summaryJSON = summaryJSON
                    fightResearch[videoID] = record
                }
            } catch {
                presentError("Could not save the fight research edits", error)
            }
        }
    }

    /// Manual (re-)run of the fight-scoring pass for one video — the same
    /// pass that runs automatically at the end of analysis.
    /// The saved limb and impact highlight of one strike. A strike scored
    /// before highlights were saved is found now and saved for next time.
    func strikeHighlight(video: VideoRecord, time: Double, fighterKey: String, detail: StrikeDetail?,
                         eventGeneration: Int64?) async -> StrikeHighlightRules.Track? {
        let profile = profileGeneration
        // Migrated legacy events predate the local counter and belong to zero.
        let generation = eventGeneration ?? 0
        guard let database,
              (try? await database.isFightEventGenerationCurrent(videoID: video.id, generation: generation)) == true,
              !Task.isCancelled, profile == profileGeneration, self.database === database else { return nil }
        if let saved = try? await database.fetchStrikeHighlight(videoID: video.id, time: time, fighterKey: fighterKey,
                                                               expectedGeneration: generation) {
            guard !Task.isCancelled, profile == profileGeneration, self.database === database else { return nil }
            return saved.track
        }
        guard !Task.isCancelled, profile == profileGeneration, self.database === database else { return nil }
        // An in-place correction keeps the generation. Capture the actual row too,
        // so a finder started before the edit cannot save its stale limb track.
        guard let expectedEvent = (try? await database.fetchFightEvents(videoID: video.id))?.first(where: {
            $0.time == time && $0.fighterKey == fighterKey && StrikeDetail($0.detail) == detail
        }) else { return nil }
        let outcome = await StrikeHighlightFinder.find(url: video.url, time: time, detail: detail, duration: video.duration)
        // Frames that could not be read say nothing: try again next time.
        guard !Task.isCancelled, profile == profileGeneration, self.database === database,
              let record = outcome.record(videoID: video.id, time: time, fighterKey: fighterKey) else { return nil }
        guard (try? await database.saveStrikeHighlights(videoID: video.id, [record], generation: generation, expectedEvent: expectedEvent)) == true,
              !Task.isCancelled, profile == profileGeneration, self.database === database else { return nil }
        strikeHighlightRevision += 1
        return outcome.track
    }

    /// Finds the limb and impact of every scored strike that has none saved,
    /// from the events already there: no AI pass. For a fight whose events
    /// arrived by sync, or whose marking was stopped part way.
    func markStrikes(video: VideoRecord) {
        guard let database, !fightScoringInFlight.contains(video.id),
              fightEvents[video.id]?.isEmpty == false else { return }
        let profile = profileGeneration
        fightScoringJobsInFlight.insert(video.id)
        jobs.start(.fightScore, title: "Mark strikes — \(video.filename)", project: activeProject,
                   profileGeneration: profileGeneration, subjectID: String(video.id), cleanup: { [weak self] in
            self?.fightScoringJobsInFlight.remove(video.id)
        }) { [self] log in
            try await StrikeHighlightMarker.mark(video: video, database: database,
                isCurrent: { @MainActor [self] in
                    profile == profileGeneration && self.database === database
                }, didSave: { @MainActor [self] in
                    guard profile == profileGeneration, self.database === database else { return }
                    strikeHighlightRevision += 1
                }, log: log)
            return nil
        }
    }

    /// Refines existing plain tracks only; the job owns the work after the popup closes.
    func makeStrikeHighlightsHD(video: VideoRecord, events: [FightEventRecord]) {
        guard let database, video.isLocal, !fightScoringInFlight.contains(video.id), !events.isEmpty else { return }
        let profile = profileGeneration
        fightScoringJobsInFlight.insert(video.id)
        strikeHighlightsBecomingHD[video.id] = Set(events.map(\.id))
        jobs.start(.fightScore, title: "HD highlight — \(video.filename)", project: activeProject,
                   profileGeneration: profile, subjectID: String(video.id), cleanup: { [weak self] in
            // A job stopped by a profile switch ends late; the same video id
            // may by then belong to a job of the new profile.
            guard let self, self.profileGeneration == profile else { return }
            self.fightScoringJobsInFlight.remove(video.id)
            self.strikeHighlightsBecomingHD[video.id] = nil
        }) { [self] log in
            do {
                try await StrikeHighlightContour.makeHD(video: video, events: events, database: database,
                    isCurrent: { @MainActor [self] in
                        profile == self.profileGeneration && self.database === database
                    }, didSave: { @MainActor [self] in
                        guard profile == self.profileGeneration, self.database === database else { return }
                        self.strikeHighlightRevision += 1
                    }, log: log)
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    ErrorLog.record("HD strike highlight", error.localizedDescription)
                }
                throw error
            }
            return nil
        }
    }

    func scoreFightAction(video: VideoRecord) {
        guard let database, !fightScoringInFlight.contains(video.id) else { return }
        fightScoringJobsInFlight.insert(video.id)
        let profile = activeProfile
        let generation = profileGeneration
        let projectID = activeProjectID
        jobs.start(.fightScore, title: "Score fight — \(video.filename)", project: activeProject,
                   profileGeneration: generation, subjectID: String(video.id), cleanup: { [weak self] in
            self?.fightScoringJobsInFlight.remove(video.id)
            self?.continueAnalysisStepBatch()
        }) { [self] jobLog in
            // The job row keeps lines in memory only; the analysis log persists them to app.log.
            let fileLog = logSink(\.analysisLog)
            let log: @Sendable (String) -> Void = { line in jobLog(line); fileLog(line) }
            do {
                _ = try await analyzer.scoreFightAction(video: video, profile: profile,
                                                        database: database, log: log)
            } catch {
                if generation == profileGeneration {
                    analysisPasses = (try? await database.fetchAnalysisPasses()) ?? []
                }
                throw error
            }
            guard generation == profileGeneration, projectID == activeProjectID else { return nil }
            let events = try await database.fetchFightEvents()
            fightEvents = Dictionary(grouping: events, by: \.videoID)
            analysisPasses = try await database.fetchAnalysisPasses()
            strikeHighlightRevision += 1
            return nil
        }
    }

    /// Load a manual-build document into the Builder for detail work.
    func openManualBuildInBuilder(_ document: TimelineDocument) {
        createTimeline(named: "Manual Edit", document: document)
    }

    /// Continue a reviewed Wizard plan in the Builder, where owned photo and
    /// B-roll suggestions can be accepted before the final render.
    func openReviewedPlanInBuilder(_ plan: WizardPlan, sceneMap: [Int64: SceneRecord], options: WizardOptions,
                                   fixWithWizard: Bool = false, named name: String = "Reviewed Plan") {
        guard let database else { return }
        let generation = profileGeneration
        let profile = activeProfile
        Task {
            do {
                let document = try await WizardEngine.timelineDocument(from: plan, sceneMap: sceneMap,
                    options: options, database: database, profile: profile, log: logSink(\.wizardLog))
                guard self.database === database, generation == profileGeneration, !Task.isCancelled else { return }
                createTimeline(named: name, document: document, projectID: options.projectID,
                               isWizardPlan: true, fixWithWizard: fixWithWizard)
            } catch {
                presentError("Could not lay out the reviewed cuts", error)
            }
        }
    }

    /// Load a generated video's saved timeline back into the builder.
    /// Videos rendered before documents were persisted stored a flat legacy
    /// format — those get a best-effort conversion (clips, transitions,
    /// music; their burned-in overlays were never recorded).
    func openInBuilder(_ video: GeneratedVideoRecord, fixWithWizard: Bool = false) {
        var document = video.timelineJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(TimelineDocument.self, from: $0) }
        if document?.videoTrack.isEmpty != false {
            let sceneMap = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
            document = WizardEngine.legacyTimelineDocument(fromFlat: video.timelineJSON,
                                                           scenes: sceneMap)
        }
        guard let document, !document.videoTrack.isEmpty else {
            presentError("This video's timeline couldn't be read, so it can't be edited in the Builder.")
            return
        }
        createTimeline(named: video.url.deletingPathExtension().lastPathComponent,
                       document: document, isWizardPlan: true, fixWithWizard: fixWithWizard,
                       reviewFlags: video.reviewFlags)
    }
}
