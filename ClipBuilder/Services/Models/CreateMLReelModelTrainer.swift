import CoreML
import CreateML
import Foundation
import Synchronization
import TabularData

nonisolated struct CreateMLReelModelTrainer: ReelModelTrainer {
  final class Predictor: ReelModelPredictor {
    private let models: Mutex<[String: MLModel]>
    private let item: ReelModelItem
    init(root: URL, item: ReelModelItem) throws {
      self.item = item
      let targets = item == .outcome ? ReelOutcome.targets : ["keep"]
      var loaded: [String: MLModel] = [:]
      for (index, target) in targets.enumerated() {
        let path = index == 0 ? root : root.appendingPathComponent(target + ".mlmodelc")
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        loaded[target] = try MLModel(contentsOf: path, configuration: configuration)
      }
      models = Mutex(loaded)
    }
    func predict(_ features: [String: Double]) throws -> [String: Double] {
      // MLModel is not Sendable: the lock confines both it and its predictions.
      try models.withLock { models in
        let input = try MLDictionaryFeatureProvider(
          dictionary: features.mapValues { NSNumber(value: $0) })
        var result: [String: Double] = [:]
        for (target, model) in models {
          let output = try model.prediction(from: input)
          if item == .ranker, let name = model.modelDescription.predictedProbabilitiesName,
            let probabilities = output.featureValue(for: name)?.dictionaryValue
          {
            result[target] = probabilities[AnyHashable(Int64(1))]?.doubleValue ?? 0
          } else {
            result[target] = output.featureValue(for: target)?.doubleValue
          }
        }
        return result
      }
    }
  }

  @concurrent
  func train(rows: [ReelModelRow], item: ReelModelItem, destination: URL) async throws
    -> ReelModelTraining
  {
    if item == .taste {
      return try await TasteSimilarity.Trainer().train(
        rows: rows, item: item, destination: destination)
    }
    guard let first = rows.first else { throw ReelModelError.unavailable("No labeled rows.") }
    let names = first.features.keys.sorted()
    let targets = item == .outcome ? ReelOutcome.targets : ["keep"]
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "create-ml-\(UUID())")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    for (index, target) in targets.enumerated() {
      try Task.checkCancellation()
      var table = DataFrame()
      for name in names {
        table.append(column: Column(name: name, contents: rows.map { $0.features[name] ?? 0 }))
      }
      let source = temporary.appendingPathComponent(target + ".mlmodel")
      if item == .ranker {
        let labels = rows.map { ($0.targets[target] ?? 0) >= 0.5 ? 1 : 0 }
        guard Set(labels).count == 2 else {
          throw ReelModelError.unavailable("The ranker needs both keep and reject examples.")
        }
        table.append(column: Column(name: target, contents: labels))
        let model = try MLLogisticRegressionClassifier(
          trainingData: table, targetColumn: target,
          featureColumns: names, parameters: .init(validation: .none, maxIterations: 100))
        try model.write(to: source)
      } else {
        table.append(column: Column(name: target, contents: rows.map { $0.targets[target] ?? 0 }))
        let model = try MLBoostedTreeRegressor(
          trainingData: table, targetColumn: target,
          featureColumns: names,
          parameters: .init(validation: .none, maxDepth: 4, maxIterations: 100, randomSeed: 42))
        try model.write(to: source)
      }
      let compiled = try await MLModel.compileModel(at: source)
      let targetURL =
        index == 0 ? destination : destination.appendingPathComponent(target + ".mlmodelc")
      try FileManager.default.copyItem(at: compiled, to: targetURL)
      try? FileManager.default.removeItem(at: compiled)
    }
    let predictor = try Predictor(root: destination, item: item)
    // Deterministic permutation importance, measured against actual fitted predictions.
    let base = try rows.map { try predictor.predict($0.features) }
    func loss(_ prediction: [[String: Double]]) -> Double {
      zip(rows, prediction).reduce(0) { sum, pair in
        sum + targets.reduce(0) { $0 + pow((pair.0.targets[$1] ?? 0) - (pair.1[$1] ?? 0), 2) }
      } / Double(rows.count)
    }
    let baseLoss = loss(base)
    var importance: [String: Double] = [:]
    for name in names {
      let prediction = try rows.indices.map { index in
        var features = rows[index].features
        features[name] = rows[(index + 1) % rows.count].features[name]
        return try predictor.predict(features)
      }
      importance[name] = max(0, loss(prediction) - baseLoss)
    }
    return ReelModelTraining(predictor: predictor, importance: importance)
  }
  func load(at url: URL, item: ReelModelItem) throws -> any ReelModelPredictor {
    if item == .taste { return try TasteSimilarity.Trainer().load(at: url, item: item) }
    return try Predictor(root: url, item: item)
  }
}
