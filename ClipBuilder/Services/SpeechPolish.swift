import Foundation

/// The audio finishing pass for a rendered reel: a high-pass for rumble,
/// FFT noise reduction, then EBU R128 loudness normalization to -16 LUFS.
/// Stored on `RenderSettings.speechPolish`; nil means "not chosen", which
/// renders without the pass.
nonisolated struct SpeechPolishSettings: Codable, Sendable, Equatable, Hashable {
    enum Strength: String, Codable, CaseIterable, Sendable, Identifiable {
        case light, standard, strong

        var id: String { rawValue }

        var label: String {
            switch self {
            case .light: "Light"
            case .standard: "Standard"
            case .strong: "Strong"
            }
        }

        /// `afftdn` noise reduction in dB.
        var noiseReduction: Int {
            switch self {
            case .light: 6
            case .standard: 9
            case .strong: 12
            }
        }
    }

    var enabled: Bool
    var strength: Strength

    init(enabled: Bool = true, strength: Strength = .standard) {
        self.enabled = enabled
        self.strength = strength
    }

    private enum CodingKeys: String, CodingKey { case enabled, strength }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        strength = (try? container.decodeIfPresent(Strength.self, forKey: .strength)) ?? .standard
    }
}

nonisolated enum SpeechPolish {
    /// Integrated loudness target, in LUFS. Instagram and TikTok normalize
    /// near this level, so a polished reel is neither turned down nor up.
    static let targetLoudness = -16.0

    /// Pure filter chain for `-af`.
    static func filter(_ settings: SpeechPolishSettings) -> String {
        "highpass=f=80,afftdn=nr=\(settings.strength.noiseReduction):nf=-40,"
            + "loudnorm=I=\(Int(targetLoudness)):TP=-1.5:LRA=11"
    }

    /// Video stream copied, audio filtered and re-encoded with the app's
    /// standard AAC settings (which resample loudnorm's 192 kHz back to 44.1).
    static func arguments(input: URL, output: URL, settings: SpeechPolishSettings) -> [String] {
        ["-y", "-i", input.path, "-map", "0:v?", "-map", "0:a", "-c:v", "copy", "-af", filter(settings)]
            + FFmpeg.audioEncodeArgs + ["-movflags", "+faststart", output.path]
    }

    /// Writes the polished file to `output`. A file without an audio stream
    /// is copied unchanged, so the pass never fails a silent render.
    @concurrent
    static func apply(input: URL, output: URL, settings: SpeechPolishSettings) async throws {
        try Task.checkCancellation()
        guard await FFmpeg.hasAudioStream(input) else {
            try FileManager.default.copyItemReplacing(at: input, to: output)
            return
        }
        try await FFmpeg.run(arguments(input: input, output: output, settings: settings),
                             timeout: 900, capture: .boundedStderrTail(),
                             purpose: "speech polish (\(settings.strength.rawValue)); video stream copy")
    }

    /// Polishes `url` in place through a sibling temporary file.
    @concurrent
    static func applyInPlace(_ url: URL, settings: SpeechPolishSettings) async throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".polish-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await apply(input: url, output: temporary, settings: settings)
        try FileManager.default.copyItemReplacing(at: temporary, to: url)
    }

    /// Wizard and Express default when neither the profile nor the run chose:
    /// on for spoken recipes and podcast/interview sources, never when any
    /// source is a fight, training session or recap, so crowd and cage
    /// ambience survive. `sourceTypes` are the classified types
    /// (`LongRecordingClassifier` or the model) of the plan's sources.
    static func wizardDefault(recipeID: String?, sourceTypes: [VideoType?]) -> SpeechPolishSettings? {
        let fightLike: Set<VideoType> = [.fight, .training, .recap]
        if sourceTypes.contains(where: { $0.map(fightLike.contains) ?? false }) { return nil }
        if let recipeID, let recipe = ReelRecipe.recipe(id: recipeID), recipe.capabilities == .fight { return nil }
        let spokenRecipes: Set<String> = [ReelRecipe.podcast.id, ReelRecipe.podcastHighlights.id, ReelRecipe.interview.id]
        if let recipeID, spokenRecipes.contains(recipeID) { return SpeechPolishSettings(enabled: true, strength: .standard) }
        let typed = sourceTypes.compactMap { $0 }
        guard !typed.isEmpty, typed.allSatisfy({ $0 == .podcast || $0 == .interview }) else { return nil }
        return SpeechPolishSettings(enabled: true, strength: .standard)
    }
}
