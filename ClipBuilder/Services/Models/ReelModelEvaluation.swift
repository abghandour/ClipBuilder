import CryptoKit
import Foundation

nonisolated struct ReelModelEvaluation: Codable, Sendable, Identifiable {
  var item: ReelModelItem
  var version: Int
  var traitsVersion: Int = ReelTraits.version
  var date: Date
  var origin: String?
  var trainingCount: Int
  var holdoutCount: Int
  var metrics: [String: Double]
  var baseline: Double
  var passed: Bool
  var importance: [String: Double]
  var artifactHash: String
  var localEvaluation: Bool
  var id: String { item.rawValue }
  var summary: String {
    "\(item.rawValue): \(passed ? "passed" : "not passed") · \(trainingCount) training / \(holdoutCount) holdout · "
      + metrics.sorted { $0.key < $1.key }.map {
        "\($0.key) \($0.value.formatted(.number.precision(.fractionLength(2))))"
      }.joined(separator: ", ")
  }
}

/// Paths are captured from the profile database, never from the global asset catalog.
nonisolated struct ReelModelStore: Sendable {
  var root: URL
  var reports: URL
  init(root: URL, reports: URL) {
    self.root = root
    self.reports = reports
  }
  init(databasePath: URL, reports: URL) {
    root = databasePath.deletingPathExtension().appendingPathComponent("models")
    self.reports = reports
  }
  func artifact(_ item: ReelModelItem, version: Int = 1) -> URL {
    root.appendingPathComponent("\(item.filename)-v\(version).\(item.artifactExtension)")
  }
  func reportURL(_ item: ReelModelItem) -> URL {
    root.appendingPathComponent(item.rawValue + "-evaluation.json")
  }
  func report(_ item: ReelModelItem) -> ReelModelEvaluation? {
    guard let data = try? Data(contentsOf: reportURL(item)) else { return nil }
    return try? JSONDecoder().decode(ReelModelEvaluation.self, from: data)
  }
  func save(_ report: ReelModelEvaluation) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    try data.write(to: reportURL(report.item), options: .atomic)
    try data.write(
      to: reports.appendingPathComponent(
        "\(report.item.rawValue)-\(Int(report.date.timeIntervalSince1970)).json"), options: .atomic)
  }
  /// Why a model can or cannot run, independent of the user's switch. The
  /// same checks gate `predictor`, so the AI Lessons page shows the truth.
  enum Eligibility: Equatable, Sendable {
    case eligible, notEvaluated, notPassed, needsLocalEvaluation, traitsOutdated, artifactChanged

    var label: String {
      switch self {
      case .eligible: "Ready"
      case .notEvaluated: "Not evaluated"
      case .notPassed: "Did not pass"
      case .needsLocalEvaluation: "Adopted, needs local evaluation"
      case .traitsOutdated: "Evaluated with older traits, evaluate again"
      case .artifactChanged: "Model file changed since evaluation, evaluate again"
      }
    }
  }
  func eligibility(_ item: ReelModelItem) -> Eligibility {
    guard let report = report(item) else { return .notEvaluated }
    guard report.passed else { return .notPassed }
    guard report.localEvaluation else { return .needsLocalEvaluation }
    guard report.traitsVersion == ReelTraits.version else { return .traitsOutdated }
    guard report.artifactHash == (try? Self.hash(artifact(item, version: report.version))) else { return .artifactChanged }
    return .eligible
  }
  func predictor(
    item: ReelModelItem, config: AIConfig,
    trainer: any ReelModelTrainer
  ) throws -> (any ReelModelPredictor)? {
    guard item.isEnabled(config: config) else { return nil }
    guard let report = report(item), eligibility(item) == .eligible
    else { throw ReelModelError.notEvaluated }
    return try trainer.load(at: artifact(item, version: report.version), item: item)
  }
  static func hash(_ directory: URL) throws -> String {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: keys)
    else {
      throw ReelModelError.unavailable("Model files are missing.")
    }
    var files: [URL] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: Set(keys))
      guard values.isSymbolicLink != true else {
        throw ReelModelError.unavailable("Model contains a symbolic link.")
      }
      if values.isRegularFile == true { files.append(url) }
    }
    guard !files.isEmpty else { throw ReelModelError.unavailable("Model files are missing.") }
    var hash = SHA256()
    for file in files.sorted(by: { $0.path < $1.path }) {
      hash.update(data: Data(file.path.dropFirst(directory.path.count).utf8))
      hash.update(data: try Data(contentsOf: file))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

nonisolated enum ReelModelEvaluator {
  /// Evaluation owns neither AIConfig nor the user's override dictionary.
  static func evaluate(
    item: ReelModelItem, rows: [ReelModelRow], store: ReelModelStore,
    trainer: any ReelModelTrainer, adopted: Bool = false,
    preferences: [(ReelTraits, ReelTraits)] = []
  ) async throws -> ReelModelEvaluation {
    let ordered = rows.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
    if item == .outcome && !adopted { try ReelOutcomeModel.requireEnough(ordered) }
    guard ordered.count >= 5 else {
      throw ReelModelError.unavailable("Needs at least five local labeled examples to evaluate.")
    }
    let holdoutCount = max(1, Int(ceil(Double(ordered.count) * 0.2)))
    let train = Array(ordered.dropLast(holdoutCount))
    let test = Array(ordered.suffix(holdoutCount))
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reel-model-\(UUID())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let old = store.report(item)
    if adopted, old?.traitsVersion != ReelTraits.version {
      throw ReelModelError.unavailable(
        "This model uses a different trait version. Ask its contributor to retrain it.")
    }
    let version = adopted ? (old?.version ?? 1) : (old?.version ?? 0) + 1
    let model: ReelModelTraining
    if adopted {
      model = ReelModelTraining(
        predictor: try trainer.load(at: store.artifact(item, version: version), item: item),
        importance: old?.importance ?? [:])
    } else {
      model = try await trainer.train(rows: train, item: item, destination: scratch)
    }
    let predictions = try test.map { try model.predictor.predict($0.features) }
    var metrics: [String: Double] = [:]
    var baseline = 0.0
    var passed = false
    if item == .outcome {
      for target in ReelOutcome.targets {
        metrics[target] = correlation(
          test.map { $0.targets[target] ?? 0 }, predictions.map { $0[target] ?? 0 })
      }
      let mean = ReelTraitExtractor.average(Array(metrics.values))
      metrics["rankCorrelation"] = mean
      passed = mean > 0.1
      if !preferences.isEmpty {
        var agreements = 0
        for (a, b) in preferences {
          let left = try model.predictor.predict(a.features)
          let right = try model.predictor.predict(b.features)
          if ReelTraitExtractor.average(Array(left.values))
            > ReelTraitExtractor.average(Array(right.values))
          {
            agreements += 1
          }
        }
        metrics["preferenceAgreement"] = Double(agreements) / Double(preferences.count)
      }
    } else {
      let truth = test.map { ($0.targets["keep"] ?? 0) >= 0.5 }
      if item == .ranker {
        let agreed = zip(truth, predictions).filter { $0.0 == (($0.1["keep"] ?? 0) >= 0.5) }.count
        metrics["agreement"] = Double(agreed) / Double(test.count)
        let baselineAgreed = zip(truth, test).filter {
          $0.0 == (($0.1.features["score"] ?? 0) >= 5)
        }.count
        baseline = Double(baselineAgreed) / Double(test.count)
        passed = (metrics["agreement"] ?? 0) > baseline
      } else {
        let top = test.indices.sorted {
          (predictions[$0]["keep"] ?? 0) > (predictions[$1]["keep"] ?? 0)
        }.prefix(10)
        let precision = Double(top.filter { truth[$0] }.count) / Double(top.count)
        metrics["topTenPrecision"] = precision
        baseline = Double(truth.filter { $0 }.count) / Double(truth.count)
        passed = precision > baseline
      }
    }
    if !adopted {
      try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
      // Retain the model trained on the older 80%, exactly the artifact measured here.
      try FileManager.default.moveItem(at: scratch, to: store.artifact(item, version: version))
    }
    let report = ReelModelEvaluation(
      item: item, version: version, date: Date(), origin: adopted ? old?.origin : nil,
      trainingCount: adopted ? 0 : train.count, holdoutCount: test.count, metrics: metrics,
      baseline: baseline,
      passed: passed, importance: model.importance,
      artifactHash: try ReelModelStore.hash(store.artifact(item, version: version)),
      localEvaluation: true)
    try store.save(report)
    return report
  }

  static func recordAgreement(_ report: ReelModelEvaluation, config: inout AIConfig) {
    guard report.localEvaluation, report.holdoutCount > 0 else { return }
    let key =
      report.item == .outcome
      ? "rankCorrelation" : report.item == .ranker ? "agreement" : "topTenPrecision"
    if let measured = report.metrics[key], measured.isFinite {
      config.onDeviceAgreement[report.item.rawValue] = measured * 100
    }
  }

  /// Spearman with average ranks for ties, zero for a constant prediction.
  static func correlation(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, a.count > 1 else { return 0 }
    func ranks(_ values: [Double]) -> [Double] {
      values.map { value in
        Double(values.filter { $0 < value }.count) + Double(values.filter { $0 == value }.count - 1)
          / 2
      }
    }
    let x = ranks(a)
    let y = ranks(b)
    let mx = ReelTraitExtractor.average(x)
    let my = ReelTraitExtractor.average(y)
    let numerator = zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
    let denominator = sqrt(
      x.reduce(0) { $0 + pow($1 - mx, 2) } * y.reduce(0) { $0 + pow($1 - my, 2) })
    return denominator > 0 ? numerator / denominator : 0
  }
}
