import Foundation

nonisolated enum OnDeviceAgreement {
    /// Cases per item in one comparison run. Each case is one or two model
    /// calls, so the run stays minutes, not hours, on a full library.
    static let sampleLimit = 5
    static let items = ["image-search", "wizard-request", "fight-queries", "file-naming", "scene-search", "hashtags", "trim", "long-recording", "duplicates", "cover-frames", "image-tagging", "podcast-exchanges", "translation-batch"]
    struct Case: Codable, Sendable {
        var id: String
        var local: String
        var model: String
        var agrees: Bool
        static func exactCase(id: String, local: String, model: String) -> Case {
            Case(id: id, local: local, model: model, agrees: local == model)
        }
    }
    struct Report: Codable, Sendable {
        var item: String
        var date: Date = Date()
        var cases: [Case]
        var errors: [String] = []
        var percentage: Double? {
            guard !cases.isEmpty else { return nil }
            return Double(cases.filter(\.agrees).count) / Double(cases.count) * 100
        }
        var passed: Bool { errors.isEmpty && (percentage ?? 0) >= 90 }
    }
    static func save(_ report: Report, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let date = ISO8601DateFormatter().string(from: report.date).replacingOccurrences(of: ":", with: "-")
        try encoder.encode(report).write(to: root.appendingPathComponent("\(report.item)-\(date).json"), options: .atomic)
    }
    static func exact(id: String, local: String, model: String) -> Case {
        Case(id: id, local: local, model: model, agrees: local == model)
    }
}
