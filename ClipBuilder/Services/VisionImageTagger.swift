import Foundation
import Vision

nonisolated enum VisionImageTagger {
    struct Signals: Sendable {
        var labels: [String: Float]
        var faces: [CGRect]
        var textArea: Double
    }
    static func inspect(_ data: Data) async throws -> Signals {
        let classify = ClassifyImageRequest()
        let faces = DetectFaceRectanglesRequest()
        var text = RecognizeTextRequest()
        text.recognitionLevel = .fast
        // Each request suspends while Vision works; never block a cooperative-pool thread.
        async let classifications = classify.perform(on: data)
        async let faceObservations = faces.perform(on: data)
        async let textObservations = text.perform(on: data)
        let results = try await (classifications, faceObservations, textObservations)
        return Signals(labels: Dictionary(results.0.map { ($0.identifier, $0.confidence) }, uniquingKeysWith: max),
            faces: results.1.map { $0.boundingBox.cgRect },
            textArea: results.2.reduce(0) { $0 + $1.boundingBox.width * $1.boundingBox.height })
    }
    static func localTag(_ signals: Signals) -> String? {
        if signals.faces.isEmpty && signals.textArea > 0.2 { return "graphic" }
        guard signals.faces.allSatisfy({ $0.width * $0.height <= 0.05 }) else { return nil }
        if (signals.labels["crowd"] ?? 0) >= 0.6 { return "crowd" }
        if ["landscape", "cityscape", "scenery"].contains(where: { (signals.labels[$0] ?? 0) >= 0.6 }) { return "establishing-shot" }
        return nil
    }
    static func hints(_ signals: Signals) -> String {
        signals.labels.filter { $0.value >= 0.1 }.sorted { $0.value > $1.value }.prefix(8)
            .map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "; faces: \(signals.faces.count)"
    }
}
