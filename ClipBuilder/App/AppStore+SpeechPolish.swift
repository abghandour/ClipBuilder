import Foundation

/// Speech Polish audition for the Builder inspector: one exact-preview slice
/// at the playhead rendered without the pass, then polished, so Original and
/// Polished are the same frames and differ only in sound.
/// See docs/Speech-Polish-Plan.md.
extension AppStore {
    struct SpeechPolishAudition: Equatable, Sendable {
        var start: Double
        var original: URL
        var polished: URL
    }

    nonisolated static let speechPolishAuditionSeconds: Double = 10

    nonisolated static var speechPolishAuditionDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SpeechPolishAudition", isDirectory: true)
    }

    /// Renders the audition pair. The render runs in the renderer actor and
    /// the polish in a `@concurrent` ffmpeg call; the main actor only awaits.
    func renderSpeechPolishAudition(settings: SpeechPolishSettings) async -> SpeechPolishAudition? {
        let start = builder.playhead
        guard let rendered = await renderBuilderExactPreview(from: start, seconds: Self.speechPolishAuditionSeconds,
                                                             withoutSpeechPolish: true) else { return nil }
        let directory = Self.speechPolishAuditionDirectory
        let id = UUID().uuidString
        let original = directory.appendingPathComponent("original-\(id).mp4")
        let polished = directory.appendingPathComponent("polished-\(id).mp4")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: rendered, to: original)
            try await SpeechPolish.apply(input: original, output: polished, settings: settings)
            appendLog(\.builderLog, ["Speech polish audition ready (\(settings.strength.label))"], channel: "builder-preview")
            return SpeechPolishAudition(start: start, original: original, polished: polished)
        } catch is CancellationError {
            Self.discardSpeechPolishAudition(nil, extra: [rendered, original, polished])
            return nil
        } catch {
            Self.discardSpeechPolishAudition(nil, extra: [rendered, original, polished])
            appendLog(\.builderLog, ["Speech polish audition failed: \(error.userMessage)"], channel: "builder-preview")
            presentError("Speech polish audition failed", error)
            return nil
        }
    }

    nonisolated static func discardSpeechPolishAudition(_ audition: SpeechPolishAudition?, extra: [URL] = []) {
        for url in extra + [audition?.original, audition?.polished].compactMap(\.self) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
