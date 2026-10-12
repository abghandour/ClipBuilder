import Foundation

nonisolated enum AnalysisPipeline {
    /// Bump when the transcript-first pass gains a stage.
    static let podcastPass = 1
    /// Bump when visual analysis gains a stage.
    static let visualPass = 1
    static let fightScorePass = 2
    static let peoplePass = 1
    static let transcriptPass = 1
    static let exchangesPass = podcastPass

    static func current(for type: VideoType?) -> Int {
        type?.usesPodcastPass == true ? podcastPass : visualPass
    }
}
