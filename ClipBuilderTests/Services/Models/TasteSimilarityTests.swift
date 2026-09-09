import Foundation
import Testing

@testable import Clip_Builder

@Suite struct TasteSimilarityTests {
  nonisolated struct Printer: TasteFeaturePrinter {
    func features(_ image: Data) throws -> [Double] { image.map { Double($0) / 255 } }
  }
  @Test func nearestNeighborUsesInjectedFeaturePrints() throws {
    let printer = Printer()
    let exemplar = Data([20, 80, 40])
    let model = TasteSimilarity.Predictor(exemplars: [
      TasteSimilarity.features(try printer.features(exemplar))
    ])
    let exact = try #require(
      try TasteSimilarity.score(image: exemplar, predictor: model, printer: printer))
    let distant = try #require(
      try TasteSimilarity.score(image: Data([255, 255, 255]), predictor: model, printer: printer))
    #expect(exact == 1)
    #expect(distant < exact)
  }
  @Test func newestHoldoutPrecision() async throws {
    let directory = try TempDirectory()
    let store = ReelModelStore(
      root: directory.url.appendingPathComponent("models"),
      reports: directory.url.appendingPathComponent("reports"))
    let rows = (0..<100).map { index in
      ReelModelRow(
        id: String(index), date: Date(timeIntervalSince1970: Double(index)),
        features: ["vision_0": index.isMultiple(of: 2) ? 0.0 : 10.0],
        targets: ["keep": index.isMultiple(of: 2) ? 1.0 : 0.0])
    }
    let report = try await ReelModelEvaluator.evaluate(
      item: .taste, rows: rows, store: store, trainer: TasteSimilarity.Trainer())
    #expect(report.trainingCount == 80)
    #expect(report.holdoutCount == 20)
    #expect(report.metrics["topTenPrecision"] == 1)
    #expect(report.baseline == 0.5)
    #expect(report.passed)
  }
}
