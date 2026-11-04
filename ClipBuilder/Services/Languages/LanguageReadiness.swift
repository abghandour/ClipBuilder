import Foundation
import Speech
import Translation

nonisolated struct LanguageAsset: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case recognizer, translation, dubVoice }
    enum State: String, Sendable { case installed, downloadable, unsupported, missing }
    var kind: Kind
    var language: String
    var state: State
    var dubEngine: DubVoiceEngine? = nil
    var missingElevenLabsKey = false
    var id: String { "\(kind.rawValue):\(language)" }
    var installable: Bool { state == .downloadable && kind != .dubVoice }
    var title: String {
        switch kind {
        case .recognizer: "\(DubLanguageChoices.name(language)) recognizer"
        case .translation:
            language.components(separatedBy: "→").map(DubLanguageChoices.languageName).joined(separator: " → ") + " translation"
        case .dubVoice:
            missingElevenLabsKey ? "ElevenLabs key" : "\(DubLanguageChoices.name(language)) dub voice"
        }
    }
}

nonisolated struct LanguageProbe: Sendable {
    var recognizer: @Sendable (String) async -> LanguageAsset.State
    var translation: @Sendable (String, String) async -> LanguageAsset.State
    var dubVoice: @Sendable (String, DubVoiceEngine?) async -> LanguageAsset.State
    var elevenLabsKey: @Sendable () throws -> String? = { try ElevenLabsKeychain().read() }

    static func dubVoiceState(language: String, engine: DubVoiceEngine?,
                              key: @Sendable () throws -> String? = { try ElevenLabsKeychain().read() },
                              cache: ElevenLabsVoiceCache = .shared) async -> LanguageAsset.State {
        if engine == .elevenLabs {
            guard let key = try? key(), !key.isEmpty else { return .missing }
            guard ElevenLabsVoices.supportedLanguages.contains(ProjectLanguageResolver.languageCode(language)) else {
                return .unsupported
            }
        }
        let voices = await DubLanguageChoices.voices(engine: engine, language: language, cache: cache)
        return voices.contains { DubLanguageChoices.matches($0.language, requested: language) } ? .installed : .missing
    }

    static let live = LanguageProbe(
        recognizer: { identifier in
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
                return .unsupported
            }
            return await SpeechTranscriber.installedLocales.contains(locale) ? .installed : .downloadable
        },
        translation: { source, target in
            switch await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)) {
            case .installed: return .installed
            case .supported: return .downloadable
            case .unsupported: return .unsupported
            @unknown default: return .unsupported
            }
        },
        dubVoice: { language, engine in
            await dubVoiceState(language: language, engine: engine)
        })
}

nonisolated enum LanguageReadiness {
    static func assets(for languages: ProjectLanguages, dubEngine: DubVoiceEngine?, probe: LanguageProbe) async -> [LanguageAsset] {
        var result: [LanguageAsset] = []
        for locale in ProjectLanguageResolver.unique(languages.spoken) {
            result.append(LanguageAsset(kind: .recognizer, language: locale, state: await probe.recognizer(locale)))
        }
        let sources = ProjectLanguageResolver.unique(languages.spoken.map(ProjectLanguageResolver.languageCode))
        let targets = ProjectLanguageResolver.unique(languages.captions.map(ProjectLanguageResolver.languageCode))
        for source in sources {
            for target in targets where source != target {
                result.append(LanguageAsset(kind: .translation, language: "\(source)→\(target)", state: await probe.translation(source, target)))
            }
        }
        for locale in ProjectLanguageResolver.unique(languages.dub) {
            let state = await probe.dubVoice(locale, dubEngine)
            let missingKey = dubEngine == .elevenLabs && state == .missing
                && ((try? probe.elevenLabsKey())?.isEmpty != false)
            result.append(LanguageAsset(kind: .dubVoice, language: locale, state: state,
                                        dubEngine: dubEngine, missingElevenLabsKey: missingKey))
        }
        return result
    }

    static func missing(_ assets: [LanguageAsset]) -> [LanguageAsset] { assets.filter { $0.state != .installed } }

    static func summary(_ assets: [LanguageAsset]) -> String? {
        let missing = missing(assets)
        guard !missing.isEmpty else { return nil }
        return missing.map { $0.title + ($0.state == .unsupported ? " (unsupported)" : "") }.joined(separator: ", ")
            + " \(missing.count == 1 ? "is" : "are") not installed on this Mac."
    }

    static func requireRecognizers(_ assets: [LanguageAsset]) throws {
        if let message = summary(assets.filter { $0.kind == .recognizer }) {
            throw ScriptError.invalid(message + " Open Sources → Install, or change Project Languages.")
        }
    }

    static func installRecognizer(_ identifier: String) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw TranscriptionError.unsupportedLocale(identifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
    }
}
