import Foundation
import Testing
@testable import Clip_Builder

struct DubAcceptanceTests {
    private func line(_ text: String?, video: Int64 = 1, language: String = "en-US", spoken: String = "x") -> DubLine {
        DubLine(clipUID: UUID(), speakerKey: "a", voice: "v", text: spoken, sourceStart: 0, sourceEnd: 1, start: 0, duration: 1,
                takeSource: text.map { DubTakeSource(videoID: video, transcriptionKey: "k", rowStart: 0, rowEnd: 1,
                                                     language: language, text: $0) })
    }

    @Test func aDubIsCoveredOnlyWhenEveryLinesTranscriptWasAccepted() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dub-accepted-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(!DubAcceptance.covers([line("Olá, tudo bem?")], accepted: DubAcceptance.load(file)))
        try DubAcceptance.remember([line("Olá, tudo bem?"), line("Sim.")], file: file)
        let accepted = DubAcceptance.load(file)
        // The same words again, reworded dub text, or fewer lines: still accepted.
        #expect(DubAcceptance.covers([line("Olá, tudo bem?", spoken: "Hi there")], accepted: accepted))
        #expect(DubAcceptance.covers([line("Sim.")], accepted: accepted))
        // New transcript text, another language or video, or a line with no transcript: ask again.
        #expect(!DubAcceptance.covers([line("Sim."), line("Texto novo")], accepted: accepted))
        #expect(!DubAcceptance.covers([line("Sim.", language: "es-ES")], accepted: accepted))
        #expect(!DubAcceptance.covers([line("Sim.", video: 2)], accepted: accepted))
        #expect(!DubAcceptance.covers([line(nil)], accepted: accepted))
        #expect(!DubAcceptance.covers([], accepted: accepted))
        // Remembering again keeps what was there.
        try DubAcceptance.remember([line("Texto novo")], file: file)
        #expect(DubAcceptance.covers([line("Sim."), line("Texto novo")], accepted: DubAcceptance.load(file)))
    }
}
