import Foundation
import Testing
@testable import Clip_Builder

/// Transcribes one audio file with the on-device recognizer and writes the
/// text beside it, for comparing recognizers on the same excerpt (whisper.cpp,
/// say). Off unless CLIPBUILDER_ASR_DIAG_AUDIO names a 16 kHz mono file;
/// CLIPBUILDER_ASR_DIAG_LOCALE defaults to pt-BR.
@Suite("Transcription diagnostic",
       .enabled(if: ProcessInfo.processInfo.environment["CLIPBUILDER_ASR_DIAG_AUDIO"] != nil))
struct TranscriptionDiagnosticTests {
    @Test("transcribe the excerpt with the on-device recognizer", .timeLimit(.minutes(30)))
    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let audio = URL(fileURLWithPath: try #require(environment["CLIPBUILDER_ASR_DIAG_AUDIO"]))
        let locale = Locale(identifier: environment["CLIPBUILDER_ASR_DIAG_LOCALE"] ?? "pt-BR")
        let started = ContinuousClock.now
        let segments = try await TranscriptionService.transcribeFile(audioURL: audio, locale: locale)
        let seconds = (ContinuousClock.now - started).seconds
        let text = segments.map { String(format: "%.1f  %@", $0.start, $0.text) }.joined(separator: "\n")
        let out = audio.deletingPathExtension().appendingPathExtension("apple.txt")
        try "\(text)\n\n[\(segments.count) segments in \(Int(seconds)) s]\n".write(to: out, atomically: true, encoding: .utf8)
        #expect(!segments.isEmpty)
    }
}
