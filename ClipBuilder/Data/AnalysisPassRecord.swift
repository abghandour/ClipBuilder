import Foundation

nonisolated struct AnalysisPassRecord: Sendable, Equatable {
    enum Pass: String, Sendable { case fightScore, strikePose, scenes, transcript, people, exchanges }
    enum Status: String, CaseIterable, Sendable { case running, completed, cancelled, failed }
    var videoID: Int64
    var pass: Pass
    var version: Int
    var status: Status
    var startedAt: String
    var completedAt: String?
    var note: String?
    var runKey: String? = nil
}
