import Foundation
import Testing

@testable import Clip_Builder

@Suite struct ReelModelTests {
  static func rows(_ count: Int = 100) -> [ReelModelRow] {
    (0..<count).map { index in
      let signal = Double((index * 37) % 101) / 100
      return ReelModelRow(
        id: String(index), date: Date(timeIntervalSince1970: Double(index)),
        features: ["signal": signal, "noise": Double((index * 17) % 29) / 29],
        targets: Dictionary(uniqueKeysWithValues: ReelOutcome.targets.map { ($0, 1 + signal * 4) }))
    }
  }

  @Test func fortyRequired() throws {
    #expect(throws: ReelModelError.self) { try ReelOutcomeModel.requireEnough(Self.rows(39)) }
    do { try ReelOutcomeModel.requireEnough(Self.rows(17)) } catch {
      #expect(error.localizedDescription.contains("23 more"))
    }
    try ReelOutcomeModel.requireEnough(Self.rows(40))
  }

  @Test func plantedSignalAndChronologicalHoldout() async throws {
    let directory = try TempDirectory()
    let store = ReelModelStore(
      root: directory.url.appendingPathComponent("models"),
      reports: directory.url.appendingPathComponent("reports"))
    let report = try await ReelModelEvaluator.evaluate(
      item: .outcome, rows: Array(Self.rows().reversed()), store: store,
      trainer: InProcessReelModelTrainer())
    #expect(report.trainingCount == 80)
    #expect(report.holdoutCount == 20)
    #expect((report.importance["signal"] ?? 0) > (report.importance["noise"] ?? 0) * 10)
    #expect((report.metrics["rankCorrelation"] ?? 0) > 0.95)
    #expect(report.passed)
    #expect(FileManager.default.fileExists(atPath: store.reportURL(.outcome).path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.reports.path).count == 1)
  }

  @Test func evaluateLeavesSwitchesUntouched() async throws {
    let fixture = try TempDatabase()
    let store = ReelModelStore(
      databasePath: fixture.path, reports: fixture.directory.url.appendingPathComponent("reports"))
    var config = AIConfig()
    config.preferOnDevice = true
    config.onDeviceOverrides = [
      "outcome-model": false, "clip-ranker": true, "taste-similarity": false,
    ]
    let before = config.onDeviceOverrides
    await #expect(throws: ReelModelError.self) {
      try await ReelModelEvaluator.evaluate(
        item: .outcome, rows: Self.rows(39), store: store, trainer: InProcessReelModelTrainer())
    }
    let report = try await ReelModelEvaluator.evaluate(
      item: .outcome, rows: Self.rows(), store: store, trainer: InProcessReelModelTrainer())
    ReelModelEvaluator.recordAgreement(report, config: &config)
    #expect(config.onDeviceAgreement["outcome-model"] == 100)
    #expect(config.onDeviceOverrides == before)
    #expect(
      try store.predictor(item: .outcome, config: config, trainer: InProcessReelModelTrainer())
        == nil)
  }

  @Test @MainActor func adoptedModelMustBeMeasuredLocally() async throws {
    let fixture = try AssetSyncFixture { _, _ in (Data(), 200, [:]) }
    let source = ReelModelStore(
      root: fixture.directory.url.appendingPathComponent("source"),
      reports: fixture.directory.url.appendingPathComponent("source-reports"))
    let target = ReelModelStore(
      root: fixture.directory.url.appendingPathComponent("target"),
      reports: fixture.directory.url.appendingPathComponent("target-reports"))
    let trainer = InProcessReelModelTrainer()
    _ = try await ReelModelEvaluator.evaluate(
      item: .outcome, rows: Self.rows(), store: source, trainer: trainer)
    var config = AIConfig()
    config.preferOnDevice = true
    config.onDeviceOverrides["outcome-model"] = true
    let manifest = try #require(
      try LearnedModelArtifact.build(
        item: .outcome, store: source, contributor: "Studio", config: config))
    try manifest.adopt(from: source.artifact(.outcome), to: target)
    #expect(target.report(.outcome)?.origin == "Studio")
    #expect(target.report(.outcome)?.localEvaluation == false)
    #expect(throws: ReelModelError.self) {
      try target.predictor(item: .outcome, config: config, trainer: trainer)
    }
    let measured = try await ReelModelEvaluator.evaluate(
      item: .outcome, rows: Self.rows(), store: target, trainer: trainer, adopted: true)
    #expect(measured.localEvaluation)
    let predictor = try #require(try target.predictor(item: .outcome, config: config, trainer: trainer))
    #expect(try predictor.predict(["signal": 0.8, "noise": 0.2])["saves"] != nil)
    try Data("changed".utf8).write(to: target.artifact(.outcome).appendingPathComponent("changed"))
    #expect(throws: ReelModelError.self) {
      try target.predictor(item: .outcome, config: config, trainer: trainer)
    }
  }

  @Test func referencesNeverTrain() {
    var traits = ReelTraits()
    traits.duration = 3
    let row = ReelOutcome(
      videoID: "1", accountID: 1, postedAt: Date(), postingMonth: "2026-09", weekday: 1, hour: 12,
      topicTags: [], traits: traits, raw: [:],
      lift: Dictionary(uniqueKeysWithValues: ReelOutcome.targets.map { ($0, 1.0) }), reference: true
    )
    #expect(ReelOutcomeModel.rows([row]).isEmpty)
  }

  @Test func offPathDoesNotLoadModelsOrChangeCriticOrScenes() async throws {
    let fixture = try TempDatabase()
    _ = try await fixture.seedVideo(sceneCount: 3)
    let scenes = try await fixture.database.fetchScenes()
    let store = ReelModelStore(
      databasePath: fixture.path, reports: fixture.directory.url.appendingPathComponent("reports"))
    var config = AIConfig()
    config.preferOnDevice = true
    config.onDeviceOverrides = Dictionary(
      uniqueKeysWithValues: ReelModelItem.allCases.map { ($0.rawValue, false) })
    #expect(
      OnDevicePolicy.comparison.withValue(true) { !ReelModelItem.outcome.isEnabled(config: config) }
    )
    let predictor = try store.predictor(item: .ranker, config: config, trainer: NeverLoad())
    #expect(try ClipRanker.ranked(scenes, predictor: predictor, limit: 1) == scenes)
    let lines = try ReelModelScoring.criticLines(
      config: config, store: store, traits: ReelTraits(), frames: [Data()], trainer: NeverLoad())
    #expect(lines.isEmpty)
    let engine = WizardEngine(ai: AIService(config: config), render: RenderEngine())
    let profile = BrandProfile(name: "Model OFF test")
    let legacy = await engine.legacyPlanPrompt(
      profile: profile, research: [:], scenes: scenes, musicNames: [],
      signals: .init(), people: [], outcomes: [], options: WizardOptions())
    let current = await engine.planPrompt(
      profile: profile, research: [:], scenes: scenes, musicNames: [],
      signals: .init(), people: [], outcomes: [], options: WizardOptions(), learnedContributors: [])
    // No new option fields, ordering, or model blocks enter the prompt while off.
    #expect(current == legacy)
  }
  nonisolated struct NeverLoad: ReelModelTrainer {
    func train(rows: [ReelModelRow], item: ReelModelItem, destination: URL) async throws
      -> ReelModelTraining
    { throw ReelModelError.notEvaluated }
    func load(at url: URL, item: ReelModelItem) throws -> any ReelModelPredictor {
      throw ReelModelError.notEvaluated
    }
  }
}
