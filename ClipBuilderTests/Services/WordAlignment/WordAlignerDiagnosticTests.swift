import Foundation
import Testing
@testable import Clip_Builder

/// Runs the real word timing model on a real file. Off unless pointed at
/// the pieces:
///   TEST_RUNNER_WORD_ALIGNER_ARCHIVE  the model archive: a path, or an http(s) address to download
///   TEST_RUNNER_WORD_ALIGNER_AUDIO    16 kHz mono wav
///   TEST_RUNNER_WORD_ALIGNER_WORDS    JSON array of {word, start, end}
///   TEST_RUNNER_WORD_ALIGNER_OUTPUT   where the re-timed words are written
struct WordAlignerDiagnosticTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static var configured: Bool {
        ["ARCHIVE", "AUDIO", "WORDS", "OUTPUT"].allSatisfy { environment["WORD_ALIGNER_\($0)"] != nil }
    }

    @Test(.enabled(if: configured), .timeLimit(.minutes(10)))
    func installsAndRetimesARealFile() async throws {
        let environment = Self.environment
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("word-aligner-diagnostic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("model", isDirectory: true)
        let installStarted = ContinuousClock.now
        // A path installs a local archive; an http(s) address downloads it
        // the way the Settings button does.
        let archive = environment["WORD_ALIGNER_ARCHIVE"]!
        let source = archive.hasPrefix("http") ? try #require(URL(string: archive)) : URL(fileURLWithPath: archive)
        try await WordAlignerModel.install(from: source, into: directory) { _ in }
        let installSeconds = (ContinuousClock.now - installStarted).seconds
        let words = try JSONDecoder().decode([TranscriptWord].self,
            from: Data(contentsOf: URL(fileURLWithPath: environment["WORD_ALIGNER_WORDS"]!)))
        let segment = TranscriptSegment(start: words.first?.start ?? 0, end: words.last?.end ?? 0,
                                        text: words.map(\.word).joined(separator: " "), words: words)
        let started = ContinuousClock.now
        let result = try await WordAligner.shared.retime(
            segments: [segment], audioURL: URL(fileURLWithPath: environment["WORD_ALIGNER_AUDIO"]!),
            modelDirectory: directory) { _ in }
        let retimeSeconds = (ContinuousClock.now - started).seconds
        let retimed = try #require(result.segments.first?.words)
        #expect(retimed.count == words.count)
        #expect(result.aligned > words.count / 2)
        let output = URL(fileURLWithPath: environment["WORD_ALIGNER_OUTPUT"]!)
        try JSONEncoder().encode(retimed).write(to: output)
        let summary = "install \(installSeconds) s, retime \(retimeSeconds) s, aligned \(result.aligned), kept \(result.kept)\n"
        try Data(summary.utf8).write(to: output.appendingPathExtension("summary.txt"))
    }
}
