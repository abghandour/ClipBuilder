import Foundation
import Vision

nonisolated protocol TasteFeaturePrinter: Sendable {
  func features(_ image: Data) async throws -> [Double]
}
nonisolated struct VisionTasteFeaturePrinter: TasteFeaturePrinter {
  func features(_ image: Data) async throws -> [Double] {
    let request = GenerateImageFeaturePrintRequest(.revision2)
    let observation = try await request.perform(on: image)
    guard observation.elementType == .float else {
      throw ReelModelError.unavailable("No Vision feature print for this frame.")
    }
    // Keep the revision-2 numeric vector format used by existing taste-index.json files.
    return observation.data.withUnsafeBytes { bytes in
      (0..<observation.elementCount).map {
        Double(bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self))
      }
    }
  }
}
nonisolated enum TasteSimilarity {
  static func features(_ vector: [Double]) -> [String: Double] {
    Dictionary(
      uniqueKeysWithValues: vector.enumerated().map { ("vision_\($0.offset)", $0.element) })
  }
  struct Predictor: ReelModelPredictor, Codable {
    var exemplars: [[String: Double]]
    func predict(_ features: [String: Double]) throws -> [String: Double] {
      // Persisted vectors use Euclidean distance; covered against FeaturePrintObservation.distance(to:).
      let distances = exemplars.filter { Set($0.keys) == Set(features.keys) }.map { exemplar in
        sqrt(features.reduce(0) { $0 + pow($1.value - (exemplar[$1.key] ?? 0), 2) })
      }
      guard let nearest = distances.min() else {
        throw ReelModelError.unavailable("No compatible taste exemplars.")
      }
      return ["keep": 1 / (1 + nearest)]
    }
  }
  /// Builds an index of the older positive frames. No model fitting and no holdout leakage.
  struct Trainer: ReelModelTrainer {
    var exemplars: [[String: Double]] = []
    func train(rows: [ReelModelRow], item: ReelModelItem, destination: URL) async throws
      -> ReelModelTraining
    {
      let predictor = Predictor(
        exemplars: exemplars + rows.filter { ($0.targets["keep"] ?? 0) >= 0.5 }.map(\.features))
      guard !predictor.exemplars.isEmpty else {
        throw ReelModelError.unavailable("Add taste exemplars or curate some scenes first.")
      }
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try JSONEncoder().encode(predictor).write(
        to: destination.appendingPathComponent("taste-index.json"), options: .atomic)
      return ReelModelTraining(predictor: predictor, importance: [:])
    }
    func load(at url: URL, item: ReelModelItem) throws -> any ReelModelPredictor {
      try JSONDecoder().decode(
        Predictor.self, from: Data(contentsOf: url.appendingPathComponent("taste-index.json")))
    }
  }
  @concurrent
  static func printFeatures(
    _ image: Data, printer: any TasteFeaturePrinter = VisionTasteFeaturePrinter()
  ) async throws -> [String: Double] {
    features(try await printer.features(image))
  }
  @concurrent
  static func scoreOnDevice(
    image: Data, predictor: any ReelModelPredictor,
    printer: any TasteFeaturePrinter = VisionTasteFeaturePrinter()
  ) async throws -> Double? {
    try await score(image: image, predictor: predictor, printer: printer)
  }
  static func score(
    image: Data, predictor: any ReelModelPredictor,
    printer: any TasteFeaturePrinter = VisionTasteFeaturePrinter()
  ) async throws -> Double? {
    let vector = try await printer.features(image)
    return try predictor.predict(features(vector))["keep"]
  }
}
