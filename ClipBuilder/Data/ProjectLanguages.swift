import Foundation

nonisolated struct ProjectLanguages: Codable, Sendable, Hashable {
    var spoken: [String] = []
    var captions: [String] = []
    var dub: [String] = []
}

nonisolated enum ProjectLanguageResolver {
    static func resolve(project: ProjectLanguages?, profile: BrandProfile) -> ProjectLanguages {
        let editing = profile.editing ?? ProfileEditingDefaults()
        let project = project ?? ProjectLanguages()
        return ProjectLanguages(
            spoken: unique(project.spoken.isEmpty ? [editing.footage.language] : project.spoken),
            captions: unique(project.captions.isEmpty
                ? profile.captionLanguages + [editing.podcast.autoTranslateLanguage] : project.captions),
            dub: unique(project.dub.isEmpty ? [editing.footage.dubLanguage ?? ""] : project.dub))
    }

    static func transcriptionLanguage(for video: VideoRecord? = nil, languages: ProjectLanguages) -> String {
        let spoken = unique(languages.spoken)
        return spoken.count == 1 ? spoken[0] : ""
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-") }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func languageCode(_ locale: String) -> String {
        Locale(identifier: locale).language.languageCode?.identifier ?? locale
    }

    static func podcastCandidates(_ spoken: [String]) -> [String] {
        unique(spoken + ["en-US", "pt-BR"])
    }
}
