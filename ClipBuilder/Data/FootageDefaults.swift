import Foundation

nonisolated struct FootageDefaults: Codable, Sendable, Hashable {
    var analysisMode = "visual"
    var language = ""
    var vocabularyHint = ""

    enum CodingKeys: String, CodingKey {
        case analysisMode = "analysis_mode"
        case language
        case vocabularyHint = "vocabulary_hint"
    }

    init() {}

    init(_ settings: AppSettings) {
        analysisMode = settings.analysisMode
        language = settings.transcribeLanguage
        vocabularyHint = settings.transcribeHint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        analysisMode = try container.decodeIfPresent(String.self, forKey: .analysisMode) ?? "visual"
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? ""
        vocabularyHint = try container.decodeIfPresent(String.self, forKey: .vocabularyHint) ?? ""
    }
}
