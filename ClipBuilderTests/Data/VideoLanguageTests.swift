import Foundation
import Testing
@testable import Clip_Builder

@Suite("Video language")
struct VideoLanguageTests {
    @Test func badgeAndChoices() {
        #expect(VideoLanguage.badge("en-US") == "EN")
        #expect(VideoLanguage.badge("pt_BR") == "PT")
        #expect(VideoLanguage.badge(nil) == nil && VideoLanguage.badge("") == nil)
        let choices = VideoLanguage.choices(including: "sv_SE", project: ["pt-BR", "de-DE"])
        #expect(choices.prefix(2) == ["en-US", "pt-BR"])
        #expect(choices.contains("sv-SE") && choices.contains("de-DE"))
        #expect(Set(choices.map { $0.lowercased() }).count == choices.count)
    }

    @Test("Transcripts and detection fill a blank language; the user's choice sticks")
    func sourcesAndPrecedence() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        #expect(try await temp.database.video(id: id)?.language == nil)

        try await temp.database.setVideoLanguage(id: id, language: "pt_BR", source: .detected)
        var video = try #require(try await temp.database.video(id: id))
        #expect(video.language == "pt-BR" && video.languageSource == "detected")

        _ = try await temp.database.replaceTranscripts(videoID: id, transcriptionKey: "k1", language: "en-US", isTranslation: false,
            segments: [TranscriptSegment(start: 0, end: 1, text: "hi", words: nil)], provider: nil, model: nil)
        video = try #require(try await temp.database.video(id: id))
        #expect(video.language == "en-US" && video.languageSource == "transcript")

        // A detection that lands after the transcript changes nothing.
        try await temp.database.setVideoLanguage(id: id, language: "de-DE", source: .detected)
        video = try #require(try await temp.database.video(id: id))
        #expect(video.language == "en-US" && video.languageSource == "transcript")

        try await temp.database.setVideoLanguage(id: id, language: "fr-FR", source: .user)
        try await temp.database.setVideoLanguage(id: id, language: "de-DE", source: .detected)
        _ = try await temp.database.replaceTranscripts(videoID: id, transcriptionKey: "k2", language: "es-ES", isTranslation: false,
            segments: [TranscriptSegment(start: 0, end: 1, text: "hola", words: nil)], provider: nil, model: nil)
        video = try #require(try await temp.database.video(id: id))
        #expect(video.language == "fr-FR" && video.languageSource == "user")

        try await temp.database.setVideoLanguage(id: id, language: nil, source: .user)
        video = try #require(try await temp.database.video(id: id))
        #expect(video.language == nil && video.languageSource == "user")
    }
}

@Suite("Video language detection trace")
struct VideoLanguageDetectionTraceTests {
    @Test("a detected source with no language is a failed detection; a user blank or a found language is not")
    func detectionFailed() {
        #expect(VideoLanguage.detectionFailed(language: nil, source: "detected"))
        #expect(VideoLanguage.detectionFailed(language: "", source: "detected"))
        #expect(!VideoLanguage.detectionFailed(language: nil, source: "user"))
        #expect(!VideoLanguage.detectionFailed(language: nil, source: nil))
        #expect(!VideoLanguage.detectionFailed(language: "pt-BR", source: "detected"))
    }

    @Test("picker titles carry the recognizer state when it is not installed")
    func choiceTitles() {
        #expect(VideoLanguage.choiceTitle("es-ES", state: .downloadable) == "\(VideoLanguage.name("es-ES")) — not installed")
        #expect(VideoLanguage.choiceTitle("es-ES", state: .unsupported) == "\(VideoLanguage.name("es-ES")) — not supported")
        #expect(VideoLanguage.choiceTitle("es-ES", state: .installed) == VideoLanguage.name("es-ES"))
        #expect(VideoLanguage.choiceTitle("es-ES", state: nil) == VideoLanguage.name("es-ES"))
    }
}
