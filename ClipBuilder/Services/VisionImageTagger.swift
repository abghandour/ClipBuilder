import Foundation
import Vision

nonisolated enum VisionImageTagger {
    struct Signals: Sendable {
        var labels: [String: Float]
        var faces: [CGRect]
        var textArea: Double
    }
    static func inspect(_ data: Data) throws -> Signals {
        let classify = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        try VNImageRequestHandler(data: data).perform([classify, faces, text])
        return Signals(labels: Dictionary((classify.results ?? []).map { ($0.identifier, $0.confidence) }, uniquingKeysWith: max),
            faces: (faces.results ?? []).map(\.boundingBox),
            textArea: (text.results ?? []).reduce(0) { $0 + $1.boundingBox.width * $1.boundingBox.height })
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
