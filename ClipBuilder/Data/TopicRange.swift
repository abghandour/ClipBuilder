import Foundation

nonisolated struct TopicRange: Identifiable, Codable, Sendable, Hashable {
    var id: Int64
    var videoID: Int64
    var title: String
    var startTime: Double
    var endTime: Double
    var summary: String
    var speakerKeys: [String]

    var duration: Double { endTime - startTime }
}
