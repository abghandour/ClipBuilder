import Foundation

extension AppStore {
  var reelModelStore: ReelModelStore? {
    database.map {
      ReelModelStore(
        databasePath: $0.path,
        reports: SettingsStore.cacheDirectory.appendingPathComponent("on-device-agreement"))
    }
  }

  func evaluateReelModel(_ item: ReelModelItem) async throws -> ReelModelEvaluation {
    guard let database, let modelStore = reelModelStore else {
      throw ReelModelError.unavailable("Open a profile first.")
    }
    let profileName = activeProfile.profileName
    let profile = activeProfile
    var rows: [ReelModelRow]
    var trainer: any ReelModelTrainer = CreateMLReelModelTrainer()
    if item == .outcome {
      rows = ReelOutcomeModel.rows(try await database.reelOutcomes())
    } else {
      if item == .ranker {
        let labeledIDs = Set(try await database.clipModelRows().map(\.id))
        let scenes = try await database.fetchScenes().filter { labeledIDs.contains(String($0.id)) }
        let videos = try await database.fetchVideos()
        for scene in scenes {
          let detectors: VideoDetectors?
          if let video = videos.first(where: { $0.id == scene.videoID }) {
            detectors = await cachedDetectors(for: video)
          } else {
            detectors = nil
          }
          _ = try await SceneTraitExtractor.traits(
            for: scene, database: database, cachedDetectors: detectors)
        }
      }
      rows = try await database.clipModelRows()
      if item == .taste {
        let scenes = try await database.fetchScenes()
        let byID = Dictionary(uniqueKeysWithValues: scenes.map { (String($0.id), $0) })
        let printer = VisionTasteFeaturePrinter()
        var printed: [ReelModelRow] = []
        for row in rows {
          try Task.checkCancellation()
          guard let scene = byID[row.id],
            let image = await ThumbnailService.jpegFrame(
              url: scene.videoURL, at: (scene.startTime + scene.endTime) / 2)
          else { continue }
          var row = row
          row.features = try await TasteSimilarity.printFeatures(image, printer: printer)
          row.targets = ["keep": scene.curated ? 1 : 0]
          printed.append(row)
        }
        rows = printed
        let cutoff =
          rows.sorted { $0.date < $1.date }.dropLast(max(1, Int(ceil(Double(rows.count) * 0.2))))
          .last?.date ?? .distantPast
        var exemplars: [[String: Double]] = []
        let heldOutPaths = Set(
          rows.filter { $0.date > cutoff }.compactMap { byID[$0.id]?.videoPath })
        for path in profile.tasteCategories.flatMap(\.exemplarFrames)
        where !heldOutPaths.contains(path) {
          guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
          exemplars.append(try await TasteSimilarity.printFeatures(data, printer: printer))
        }
        for url in try await database.topLiftReelFiles(before: cutoff) {
          if let image = await ThumbnailService.jpegFrame(url: url, at: 1) {
            exemplars.append(try await TasteSimilarity.printFeatures(image, printer: printer))
          }
        }
        trainer = TasteSimilarity.Trainer(exemplars: exemplars)
      }
    }
    let adopted = modelStore.report(item)?.origin != nil
    let preferences = item == .outcome ? try await database.modelPreferencePairs() : []
    let report = try await ReelModelEvaluator.evaluate(
      item: item, rows: rows, store: modelStore,
      trainer: trainer, adopted: adopted, preferences: preferences)
    if activeProfile.profileName == profileName {
      // Only measured numbers; this action never changes onDeviceOverrides.
      ReelModelEvaluator.recordAgreement(report, config: &settings.ai)
    }
    return report
  }

}
