import Foundation
import CoreGraphics
import ImageIO
import Vision
import Testing

@testable import Clip_Builder

@Suite struct TasteSimilarityTests {
  nonisolated struct Printer: TasteFeaturePrinter {
    func features(_ image: Data) async throws -> [Double] { image.map { Double($0) / 255 } }
  }
  @Test func nearestNeighborUsesInjectedFeaturePrints() async throws {
    let printer = Printer()
    let exemplar = Data([20, 80, 40])
    let model = TasteSimilarity.Predictor(exemplars: [
      TasteSimilarity.features(try await printer.features(exemplar))
    ])
    let exactScore = try await TasteSimilarity.score(image: exemplar, predictor: model, printer: printer)
    let distantScore = try await TasteSimilarity.score(
      image: Data([255, 255, 255]), predictor: model, printer: printer)
    let exact = try #require(exactScore)
    let distant = try #require(distantScore)
    #expect(exact == 1)
    #expect(distant < exact)
  }
  @Test func persistedVectorsMatchVisionDistance() async throws {
    let first = try fixture(inverted: false)
    let second = try fixture(inverted: true)
    let request = GenerateImageFeaturePrintRequest(.revision2)
    let firstPrint = try await request.perform(on: first)
    let secondPrint = try await request.perform(on: second)
    let distance = try firstPrint.distance(to: secondPrint)
    let exemplar = try await TasteSimilarity.printFeatures(first)
    let predictor = TasteSimilarity.Predictor(exemplars: [exemplar])
    let score = try await TasteSimilarity.score(image: second, predictor: predictor)
    let actual = try #require(score)
    let exactScore = try await TasteSimilarity.score(image: first, predictor: predictor)
    let exact = try #require(exactScore)
    // Production scoring keeps its persisted Euclidean vector form (taste-index.json
    // compatibility), so it is not numerically equal to Vision's own distance; it must
    // agree on ordering: identical image scores highest, and a real Vision distance
    // between the two fixtures corresponds to a strictly lower score.
    #expect(distance > 0)
    #expect(abs(exact - 1) < 0.00001)
    #expect(actual > 0 && actual < exact)
  }

  private func fixture(inverted: Bool) throws -> Data {
    let context = try #require(CGContext(
      data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: inverted ? 0 : 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    context.setFillColor(CGColor(gray: inverted ? 1 : 0, alpha: 1))
    context.fill(CGRect(x: 8, y: 16, width: 24, height: 40))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
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
