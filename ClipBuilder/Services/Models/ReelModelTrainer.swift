import Foundation

nonisolated enum ReelModelItem: String, Codable, CaseIterable, Sendable {
  case outcome = "outcome-model"
  case ranker = "clip-ranker"
  case taste = "taste-similarity"
  /// Legacy comparison runs use a TaskLocal override. Fitted models always
  /// require the user's actual switch and their own local holdout gate.
  func isEnabled(config: AIConfig) -> Bool {
    config.preferOnDevice && (config.onDeviceOverrides[rawValue] ?? false)
  }
  var artifactExtension: String { self == .taste ? "visionindex" : "mlmodelc" }
  var filename: String { self == .outcome ? "reel-outcome" : rawValue }
}
nonisolated struct ReelModelRow: Codable, Sendable {
  var id: String
  var date: Date
  var features: [String: Double]
  var targets: [String: Double]
}
nonisolated protocol ReelModelPredictor: Sendable {
  func predict(_ features: [String: Double]) throws -> [String: Double]
}
nonisolated protocol ReelModelTrainer: Sendable {
  func train(rows: [ReelModelRow], item: ReelModelItem, destination: URL) async throws
    -> ReelModelTraining
  func load(at url: URL, item: ReelModelItem) throws -> any ReelModelPredictor
}
nonisolated struct ReelModelTraining: Sendable {
  var predictor: any ReelModelPredictor
  var importance: [String: Double]
}
nonisolated enum ReelModelError: LocalizedError {
  case needsRows(Int)
  case unavailable(String)
  case notEvaluated
  var errorDescription: String? {
    switch self {
    case .needsRows(let count): "Needs \(count) more labeled reels (40 required)."
    case .unavailable(let reason): reason
    case .notEvaluated: "Evaluate this model locally before using it."
    }
  }
}

/// Deterministic regression for tests, intentionally never used by the production factory.
/// Standardized coordinate descent recovers planted signals without Create ML.
nonisolated struct InProcessReelModelTrainer: ReelModelTrainer {
  struct Predictor: ReelModelPredictor, Codable {
    var means: [String: Double]
    var scales: [String: Double]
    var intercepts: [String: Double]
    var weights: [String: [String: Double]]
    func predict(_ features: [String: Double]) throws -> [String: Double] {
      var result = intercepts
      for (target, coefficients) in weights {
        var prediction = intercepts[target] ?? 0
        for (name, weight) in coefficients {
          let centered = (features[name] ?? 0) - (means[name] ?? 0)
          prediction += weight * centered / (scales[name] ?? 1)
        }
        result[target] = prediction
      }
      return result
    }
  }
  func train(rows: [ReelModelRow], item: ReelModelItem, destination: URL) async throws
    -> ReelModelTraining
  {
    guard !rows.isEmpty else { throw ReelModelError.unavailable("No labeled rows.") }
    let names = rows[0].features.keys.sorted()
    let targets = rows[0].targets.keys.sorted()
    var model = Predictor(means: [:], scales: [:], intercepts: [:], weights: [:])
    for name in names {
      let values = rows.map { $0.features[name] ?? 0 }
      let mean = ReelTraitExtractor.average(values)
      model.means[name] = mean
      model.scales[name] = max(
        0.000001, sqrt(ReelTraitExtractor.average(values.map { pow($0 - mean, 2) })))
    }
    var importance: [String: Double] = [:]
    for target in targets {
      let y = rows.map { $0.targets[target] ?? 0 }
      let intercept = ReelTraitExtractor.average(y)
      model.intercepts[target] = intercept
      var residual = y.map { $0 - intercept }
      var weights: [String: Double] = [:]
      for _ in 0..<100 {
        for name in names {
          let x = rows.map {
            (($0.features[name] ?? 0) - (model.means[name] ?? 0)) / (model.scales[name] ?? 1)
          }
          let old = weights[name] ?? 0
          let denominator = x.reduce(0) { $0 + $1 * $1 } + 0.01
          let weight = zip(x, residual).reduce(0) { $0 + $1.0 * ($1.1 + old * $1.0) } / denominator
          for index in residual.indices { residual[index] += (old - weight) * x[index] }
          weights[name] = weight
        }
      }
      model.weights[target] = weights
      for (name, weight) in weights { importance[name, default: 0] += abs(weight) }
    }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try JSONEncoder().encode(model).write(
      to: destination.appendingPathComponent("fake.json"), options: .atomic)
    return ReelModelTraining(predictor: model, importance: importance)
  }
  func load(at url: URL, item: ReelModelItem) throws -> any ReelModelPredictor {
    try JSONDecoder().decode(
      Predictor.self, from: Data(contentsOf: url.appendingPathComponent("fake.json")))
  }
}
