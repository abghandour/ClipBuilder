import Foundation

/// The finished fight story job: the timeline it created and the card copy
/// it used, for the review sheet's Open in Builder.
nonisolated struct FightStoryReview: Equatable, Sendable {
    var timelineID: Int64
    var timelineName: String
    var card: FightStoryBuilder.StoryCardCopy
    /// Where the card copy came from: the model, the user's own text, or
    /// the outcome and research records.
    var cardSource: CardSource
    var provenance: AIProvenance?
    var clipCount: Int
    var hasStat: Bool

    enum CardSource: String, Sendable { case ai, user, records }
}

/// Evidence-linked fight stories: an interview claim, a fight sequence and
/// an outcome card in one Builder timeline, with provenance on every clip
/// and the card. Runs as a background job; see docs/Fight-Story-Plan.md.
extension AppStore {
    /// True while a story is being built from this fight video.
    func isBuildingFightStory(fightVideoID: Int64) -> Bool {
        jobs.running.contains { $0.kind == .fightStory && $0.subjectID == String(fightVideoID) }
    }

    /// Load the picks, scenes, outcome, research and (optionally) strike
    /// stats, write the card copy (the user's when given, else the model's,
    /// else `fallbackCard`), build the document and save it as a timeline.
    func startFightStory(claimPickID: Int64, fightVideoID: Int64, fightPickIDs: [Int64], includeStats: Bool,
                         card userCard: FightStoryBuilder.StoryCardCopy? = nil) {
        guard let database else { return }
        guard let projectID = activeProjectID else {
            presentError("Open a project first: the story is saved as one of its timelines.")
            return
        }
        guard !fightPickIDs.isEmpty else {
            presentError("Pick at least one fight sequence for the story.")
            return
        }
        let generation = profileGeneration
        let renderSettings = activeProfile.defaultRenderSettings
        let ai = ai
        let label = fightResearch[fightVideoID]?.fightLabel
        let fightName = (label?.isEmpty == false ? label : nil)
            ?? videos.first { $0.id == fightVideoID }?.filename ?? "Fight"
        jobs.start(.fightStory, title: "Fight Story — \(fightName)", project: activeProject,
                   profileGeneration: generation, subjectID: String(fightVideoID)) { [weak self] log in
            guard let claim = try await database.transcriptPick(id: claimPickID),
                  let claimVideo = try await database.video(id: claim.videoID) else {
                throw AppJobEmptyResult(message: "The interview pick is gone. Pick a claim again.")
            }
            guard let fightVideo = try await database.video(id: fightVideoID) else {
                throw AppJobEmptyResult(message: "The fight video is gone.")
            }
            let available = try await database.fetchFightPicks(projectID: nil, videoID: fightVideoID)
            let fight = fightPickIDs.compactMap { id in available.first { $0.id == id } }
            guard !fight.isEmpty else {
                throw AppJobEmptyResult(message: "The fight picks are gone. Pick fight sequences again.")
            }
            log("Preparing scenes for the claim and \(fight.count) fight sequence(s)…")
            guard let claimScene = try await database.storyScene(videoID: claim.videoID, start: claim.start,
                                                                 end: claim.end) else {
                throw AppJobEmptyResult(message: "The interview pick has no usable range.")
            }
            var fightScenes: [Int64: SceneRecord] = [:]
            for pick in fight {
                try Task.checkCancellation()
                fightScenes[pick.id] = try await database.storyScene(videoID: fightVideoID, start: pick.start,
                                                                     end: pick.end)
            }
            let outcome = try await database.fetchOutcomes().first { $0.videoID == fightVideoID }
            let research = try await database.fetchFightResearch().first { $0.videoID == fightVideoID }
            let roster = try await database.fetchVideoPeople(videoID: fightVideoID)
            let names = Dictionary(roster.map { ($0.key, $0.displayName) }, uniquingKeysWith: { first, _ in first })
            let rows = try await database.fetchTranscripts(videoID: claim.videoID).filter { !$0.isTranslation }
            let claimText = MiniWizardTranscriptRules.text(for: claim.range, rows: rows)
            let fightLabel = research?.fightLabel.isEmpty == false ? research?.fightLabel ?? fightName : fightName

            var stat: StrikeStatPayload?
            if includeStats {
                log("Counting strike stats…")
                let request = StrikeStatPayload(kind: .roundCard, sourceVideoID: fightVideoID, sourceTime: 0,
                                                unit: .kmh, scope: .init(isRecap: fightVideo.type == .recap))
                do {
                    stat = try await AppStore.strikeStatsSnapshot(request, database: database)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    log("Strike stats unavailable: \(error.userMessage)")
                }
            }

            var card: FightStoryBuilder.StoryCardCopy
            var source: FightStoryReview.CardSource
            var provenance: AIProvenance?
            if let userCard, !userCard.isEmpty {
                card = userCard
                source = .user
            } else {
                card = FightStoryBuilder.fallbackCard(outcome: outcome, research: research, fightLabel: fightLabel,
                                                      names: names)
                source = .records
                log("Writing the outcome card…")
                do {
                    let response = try await ai.call(
                        prompt: FightStoryBuilder.prompt(claimText: claimText, fightLabel: fightLabel,
                                                         outcome: outcome, research: research),
                        task: .storyCard, log: log)
                    if let parsed = FightStoryBuilder.parseCard(response.text) {
                        card = parsed
                        source = .ai
                        provenance = response.provenance
                    } else {
                        log("The model's card was unreadable; using the outcome and research records.")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    log("Card copy from the model failed (\(error.userMessage)); using the outcome and research records.")
                }
            }

            let cardDuration = FightStoryBuilder.defaultCardDuration
            let backdrop = FightStoryBuilder.backdropRange(fight: fight, videoDuration: fightVideo.duration,
                                                           cardDuration: cardDuration)
            let backdropScene = try await database.storyScene(videoID: fightVideoID, start: backdrop.lowerBound,
                                                              end: backdrop.upperBound)
            let input = FightStoryBuilder.Input(claim: claim, claimScene: claimScene, claimVideo: claimVideo,
                                                fight: fight, fightScenes: fightScenes, fightVideo: fightVideo,
                                                outcome: outcome, research: research, card: card, stat: stat,
                                                cardDuration: cardDuration, claimText: claimText,
                                                backdropScene: backdropScene)
            let document = FightStoryBuilder.build(input, renderSettings: renderSettings)

            guard let self, self.profileGeneration == generation, self.database === database else { return nil }
            let name = "\(fightLabel) story"
            var createdID: Int64?
            await self.createTimeline(named: name, document: document, projectID: projectID, open: false,
                                      onCreated: { createdID = $0 })?.value
            guard let createdID else {
                throw AppJobEmptyResult(message: "Could not save the story timeline.")
            }
            log("Saved \"\(name)\": \(document.videoTrack.count) clip(s) and the outcome card.")
            return .fightStory(FightStoryReview(timelineID: createdID, timelineName: name, card: card,
                                                cardSource: source, provenance: provenance,
                                                clipCount: document.videoTrack.count, hasStat: stat != nil))
        }
    }

    /// Open a story timeline from its review sheet.
    @discardableResult
    func openFightStory(timelineID: Int64) -> Bool {
        guard let timeline = timelines.first(where: { $0.id == timelineID }) else {
            presentError("Open the story's project to see its timeline.")
            return false
        }
        openTimelineRecord(timeline)
        selectSection(.timelines)
        return true
    }
}
