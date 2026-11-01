import Foundation

/// The AI Lessons teaching queue (docs/Teaching-Queue-Plan.md): gather every
/// opinion about the profile's generated reels, rank where they disagree, and
/// re-evaluate the models a human answer informs.
extension AppStore {
    func refreshTeachingQueue() async {
        guard let database, let modelStore = reelModelStore, !isRefreshingTeachingQueue else { return }
        let generation = profileGeneration
        isRefreshingTeachingQueue = true
        defer { if generation == profileGeneration { isRefreshingTeachingQueue = false } }
        do {
            let videos = try await database.fetchGeneratedVideos()
            let ids = videos.map(\.id)
            let reelTraits = try await database.generatedReelTraits(ids: ids)
            let verdicts = try await database.reviewVerdicts()
            let preferred = try await database.preferenceVideoIDs()
            let sceneIDs = try await AppJobWork.run { Set(videos.flatMap(TeachingQueue.sceneIDs)) }
            let scenes = try await database.fetchScenes(ids: sceneIDs)
            let sceneTraits = try await database.cachedSceneTraits(scenes)
            // Eligible models are read even while their Use switch is off: the
            // queue only shows where they disagree, it never acts on them.
            let (signals, items) = try await AppJobWork.run {
                let trainer = CreateMLReelModelTrainer()
                func load(_ item: ReelModelItem) -> (any ReelModelPredictor)? {
                    guard modelStore.eligibility(item) == .eligible, let report = modelStore.report(item) else { return nil }
                    return try? trainer.load(at: modelStore.artifact(item, version: report.version), item: item)
                }
                let signals = TeachingQueue.signals(
                    videos: videos, reelTraits: reelTraits,
                    scenes: Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                    sceneTraits: sceneTraits, verdicts: verdicts, preferred: preferred,
                    outcome: load(.outcome), ranker: load(.ranker))
                return (signals, TeachingQueue.rank(signals: signals))
            }
            guard generation == profileGeneration else { return }
            let byID = Dictionary(signals.map { ($0.reelID, $0) }, uniquingKeysWith: { a, _ in a })
            // Only pair picks inform an on-device model (reel items inform none).
            for item in teachingQueue where item.isAnswered(by: byID) {
                teachingPending.formUnion(item.informs)
            }
            teachingQueue = items
            let needed = Set(items.flatMap(\.kind.reelIDs))
            teachingQueueVideos = Dictionary(
                videos.filter { needed.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        } catch is CancellationError {
        } catch {
            guard generation == profileGeneration else { return }
            presentError("Could not build the teaching queue", error)
        }
    }

    /// Present the side-by-side pick for a teaching-queue pair.
    func judgeTeachingPair(_ a: Int64, _ b: Int64) {
        guard let left = teachingQueueVideos[a], let right = teachingQueueVideos[b] else { return }
        let batch = ComparisonBatch(id: "teaching-\(a)-\(b)", videos: [left, right])
        comparisonQueue.removeAll { $0.id == batch.id }
        comparisonQueue.append(batch)
        if pendingComparison == nil { pendingComparison = comparisonQueue.first }
    }

    /// Retrain every model with a pending teaching answer. Eligibility, and so
    /// the Use switch, is decided by each evaluation as usual.
    func reevaluateTaughtModels() {
        for item in ReelModelItem.allCases where teachingPending.contains(item) {
            startModelEvaluation(item)
        }
        teachingPending = []
    }
}
