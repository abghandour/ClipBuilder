import Testing
import Foundation
@testable import Clip_Builder

struct TranscriptionLanguageRulesTests {
    @Test func shortFilesSampleTheOpeningMinute() {
        #expect(TranscriptionLanguageRules.sampleWindows(duration: 0) == [.init(start: 0, length: 60)])
        #expect(TranscriptionLanguageRules.sampleWindows(duration: 80) == [.init(start: 0, length: 60)])
    }

    @Test func longFilesSampleThreeWindowsAcrossTheFile() {
        let windows = TranscriptionLanguageRules.sampleWindows(duration: 600)
        #expect(windows.map(\.start) == [60, 270, 480])
        #expect(windows.allSatisfy { $0.length == 20 })
        // The last window never runs past the end.
        let tight = TranscriptionLanguageRules.sampleWindows(duration: 90)
        #expect(tight.last == .init(start: 70, length: 20))
    }

    @Test func sampleArgumentsSeekEveryWindow() {
        let windows: [TranscriptionLanguageRules.Window] = [.init(start: 0, length: 20), .init(start: 45.5, length: 20)]
        let arguments = TranscriptionLanguageRules.sampleArguments(windows: windows, source: "/in.mp4", output: "/out.wav")
        #expect(arguments == ["-y", "-ss", "0.000", "-t", "20.000", "-i", "/in.mp4",
                              "-ss", "45.500", "-t", "20.000", "-i", "/in.mp4",
                              "-vn", "-filter_complex", "[0:a][1:a]concat=n=2:v=0:a=1[out]", "-map", "[out]",
                              "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", "/out.wav"])
        #expect(TranscriptionLanguageRules.sampleLength(windows) == 40)
    }

    @Test func storedTranscriptUsability() {
        var video = Fixtures.video()
        video.duration = 258
        // A user-chosen Portuguese video with an 11-second English transcript.
        video.language = "pt-BR"
        video.languageSource = VideoLanguage.Source.user.rawValue
        #expect(!TranscriptionLanguageRules.transcriptUsable(language: "en", spokenSeconds: 10, video: video))
        #expect(!TranscriptionLanguageRules.transcriptUsable(language: "en", spokenSeconds: 200, video: video))
        #expect(TranscriptionLanguageRules.transcriptUsable(language: "pt", spokenSeconds: 200, video: video))
        // A detected language is a hint: a full English transcript stays.
        video.languageSource = VideoLanguage.Source.detected.rawValue
        #expect(TranscriptionLanguageRules.transcriptUsable(language: "en", spokenSeconds: 200, video: video))
        #expect(!TranscriptionLanguageRules.transcriptUsable(language: "en", spokenSeconds: 10, video: video))
        // Short clips and unknown durations are never thin.
        video.duration = 20
        #expect(TranscriptionLanguageRules.transcriptUsable(language: "en", spokenSeconds: 1, video: video))
        video.duration = 0
        #expect(TranscriptionLanguageRules.transcriptUsable(language: "en", spokenSeconds: 1, video: video))
        #expect(!TranscriptionLanguageRules.transcriptUsable(rows: [], video: video))
    }

    @Test func betterLanguageNeedsAClearWin() {
        // Portuguese follows most of the sample the English pass missed.
        #expect(TranscriptionLanguageRules.betterLanguage(baseline: 0.02, candidates: [("pt_BR", 0.9), ("ja_JP", 0.05)]) == "pt_BR")
        // Crowd noise: nobody follows much, so the first language stands.
        #expect(TranscriptionLanguageRules.betterLanguage(baseline: 0.04, candidates: [("pt_BR", 0.06)]) == nil)
        // A candidate barely ahead of a real baseline is noise, not a win.
        #expect(TranscriptionLanguageRules.betterLanguage(baseline: 0.3, candidates: [("pt_BR", 0.45)]) == nil)
        #expect(TranscriptionLanguageRules.betterLanguage(baseline: 0, candidates: []) == nil)
    }

    @Test func coverageAndRetryDecision() {
        let thin = [TranscriptSegment(start: 0, end: 1.2, text: "Hello", words: nil)]
        let coverage = TranscriptionLanguageRules.coverage(segments: thin, duration: 300)
        #expect(abs(coverage - 0.004) < 0.0001)
        #expect(TranscriptionLanguageRules.shouldRetryInOtherLanguages(coverage: coverage, duration: 300))
        // A short clip with one line is not evidence of the wrong language.
        #expect(!TranscriptionLanguageRules.shouldRetryInOtherLanguages(coverage: 0.05, duration: 20))
        let full = (0..<10).map { TranscriptSegment(start: Double($0) * 30, end: Double($0) * 30 + 25, text: "x", words: nil) }
        #expect(abs(TranscriptionLanguageRules.coverage(segments: full, duration: 300) - 250 / 300) < 0.0001)
        #expect(!TranscriptionLanguageRules.shouldRetryInOtherLanguages(coverage: 250 / 300, duration: 300))
        #expect(TranscriptionLanguageRules.coverage(segments: [], duration: 0) == 0)
    }
}
