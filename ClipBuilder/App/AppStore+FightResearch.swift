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
    func scoreFightAction(video: VideoRecord) {
        guard let database, !fightScoringInFlight.contains(video.id) else { return }
        fightScoringInFlight.insert(video.id)
        let profile = activeProfile
        Task {
            do {
                let scenes = ((try? await database.fetchScenes(includeExcluded: true)) ?? [])
                    .filter { $0.videoID == video.id }
                _ = try await analyzer.scoreFightAction(
                    video: video, scenes: scenes, profile: profile, database: database,
                    log: logSink(\.analysisLog))
                let events = (try? await database.fetchFightEvents()) ?? []
                fightEvents = Dictionary(grouping: events, by: \.videoID)
            } catch {
                presentError("Fight scoring failed for \(video.filename)", error)
            }
            fightScoringInFlight.remove(video.id)
        }
    }

    /// Load a manual-build document into the Builder for detail work.
    func openManualBuildInBuilder(_ document: TimelineDocument) {
        createTimeline(named: "Manual Edit", document: document)
    }

    /// Continue a reviewed Wizard plan in the Builder, where owned photo and
    /// B-roll suggestions can be accepted before the final render.
    func openReviewedPlanInBuilder(_ plan: WizardPlan, request: ProposedCutReviewRequest, fixWithWizard: Bool = false) {
        let document = WizardEngine.timelineDocument(
            from: plan, sceneMap: request.sceneMap,
            renderSettings: request.options.renderSettings,
            pacing: request.options.pacing
        )
        createTimeline(named: "Reviewed Plan", document: document, projectID: request.options.projectID,
                       isWizardPlan: true, fixWithWizard: fixWithWizard)
        pendingCutReview = nil
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
                       document: document, isWizardPlan: true, fixWithWizard: fixWithWizard)
    }
}
