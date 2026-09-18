import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

/// Runs the speaker map on a real recording and writes a report, for
/// judging tracker changes against the same podcast. Off unless
/// CLIPBUILDER_SPEAKER_DIAG_DB names a profile database copy whose video
/// (CLIPBUILDER_SPEAKER_DIAG_VIDEO, default 15) points at a local file;
/// the report goes to CLIPBUILDER_SPEAKER_DIAG_REPORT.
@Suite("Speaker map diagnostic",
       .enabled(if: ProcessInfo.processInfo.environment["CLIPBUILDER_SPEAKER_DIAG_DB"] != nil))
struct SpeakerMapDiagnosticTests {
    @Test("map the speakers of the reference podcast and report the turns", .timeLimit(.minutes(60)))
    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let dbPath = try #require(environment["CLIPBUILDER_SPEAKER_DIAG_DB"])
        let videoID = Int64(environment["CLIPBUILDER_SPEAKER_DIAG_VIDEO"] ?? "15") ?? 15
        let reportPath = environment["CLIPBUILDER_SPEAKER_DIAG_REPORT"] ?? dbPath + ".report.txt"
        let database = try Database(path: URL(fileURLWithPath: dbPath))
        let video = try #require(try await database.fetchVideos().first { $0.id == videoID })
        let before = try await database.fetchSpeakerTurns(videoID: videoID)
        let rowsBefore = try await database.fetchTranscripts(videoID: videoID).filter { !$0.isTranslation }

        let lines = Mutex<[String]>([])
        let outcomes = Mutex<[SpeakerTracker.Outcome]>([])
        let started = ContinuousClock.now
        let turns = try await PodcastAnalysisService.mapSpeakers(
            video: video, database: database, holdSeconds: 1.5,
            outcomeSink: { outcome in outcomes.withLock { $0.append(outcome) } },
            log: { line in lines.withLock { $0.append(line) } })
        let outcome = outcomes.withLock { $0.first }
        var tileOf: [String: Int] = [:]
        for turn in outcome?.turns ?? [] {
            if let tile = turn.tile { tileOf[SpeakerTurnCleanup.identity(turn)] = tile }
        }
        /// Mean enrolled posterior of a tile over a time range.
        func audio(for tile: Int?, from start: Double, to end: Double) -> String {
            guard let outcome, let tile, !outcome.enrolledVoices.isEmpty else { return "?" }
            let first = max(0, Int(start / 0.25)), last = min(outcome.enrolledVoices.count - 1, Int(end / 0.25))
            guard first <= last else { return "?" }
            let mean = (first...last).reduce(0.0) { $0 + (outcome.enrolledVoices[$1][safe: tile] ?? 0) } / Double(last - first + 1)
            return String(format: "%.2f", mean)
        }
        let elapsed = (ContinuousClock.now - started).seconds
        let rows = try await database.fetchTranscripts(videoID: videoID).filter { !$0.isTranslation }
        let words = rows.flatMap { $0.words ?? [] }.sorted { $0.start < $1.start }

        func summary(_ turns: [SpeakerTurn]) -> String {
            let short = turns.filter { $0.end - $0.start < 3 }
            let byIdentity = Dictionary(grouping: turns, by: SpeakerTurnCleanup.identity)
                .map { key, list in "\(key): \(list.count) turns, \(Int(list.reduce(0) { $0 + $1.end - $1.start })) s" }
                .sorted()
            return "\(turns.count) turns, \(Set(turns.map(\.cluster)).count) clusters, \(short.count) under 3 s, "
                + "speech \(Int(turns.reduce(0) { $0 + $1.end - $1.start })) s\n  " + byIdentity.joined(separator: "\n  ")
        }
        // Hops: a short turn between two turns of one other speaker, with
        // the words around it so a reader can tell a reaction from an answer.
        var hops: [String] = []
        let sorted = turns.sorted { $0.start < $1.start }
        for index in 1..<(max(1, sorted.count - 1)) where sorted.count >= 3 {
            let turn = sorted[index]
            guard turn.end - turn.start < 3,
                  SpeakerTurnCleanup.identity(sorted[index - 1]) == SpeakerTurnCleanup.identity(sorted[index + 1]),
                  SpeakerTurnCleanup.identity(turn) != SpeakerTurnCleanup.identity(sorted[index - 1]) else { continue }
            let around = words.filter { $0.end > turn.start - 1.5 && $0.start < turn.end + 1.5 }
            let text = around.map { word in
                let inside = (word.start + word.end) / 2 >= turn.start && (word.start + word.end) / 2 < turn.end
                return inside ? "[\(word.word.trimmingCharacters(in: .whitespaces))]" : word.word.trimmingCharacters(in: .whitespaces)
            }.joined(separator: " ")
            let inner = SpeakerTurnCleanup.identity(turn), outer = SpeakerTurnCleanup.identity(sorted[index - 1])
            hops.append(String(format: "%7.1f–%6.1f  %@ inside %@ [voice says %@ %@ / %@ %@]: %@", turn.start, turn.end,
                               inner, outer, inner, audio(for: tileOf[inner], from: turn.start, to: turn.end),
                               outer, audio(for: tileOf[outer], from: turn.start, to: turn.end), text))
        }
        var histogram = ""
        if let outcome, !outcome.enrolledVoices.isEmpty {
            var buckets = [0, 0, 0, 0]   // max posterior < 0.6, < 0.8, < 0.95, >= 0.95 over speech bins
            for (b, voices) in outcome.enrolledVoices.enumerated() where outcome.bins[b].speech {
                let top = voices.max() ?? 0
                buckets[top < 0.6 ? 0 : top < 0.8 ? 1 : top < 0.95 ? 2 : 3] += 1
            }
            histogram = "Enrolled posterior over speech bins: <0.6: \(buckets[0]), 0.6–0.8: \(buckets[1]), 0.8–0.95: \(buckets[2]), ≥0.95: \(buckets[3])"
        }
        let report = """
        Speaker map diagnostic — \(video.filename), \(Int(video.duration)) s, ran in \(Int(elapsed)) s

        Before: \(summary(before))
        After:  \(summary(turns))
        Transcript rows: \(rowsBefore.count) before, \(rows.count) after

        Log:
        \(lines.withLock { $0 }.map { "  " + $0 }.joined(separator: "\n"))
        \(histogram)

        Hops (short turn inside another speaker's stretch; the hop's words in brackets): \(hops.count)
        \(hops.joined(separator: "\n"))
        """
        try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        #expect(!turns.isEmpty)
    }
}
