import Foundation

/// Portable "Wizard Brain": everything the wizard has learned that transfers
/// between machines, profiles, and users — lessons, taste rubrics with their
/// exemplar frames, and the house style. Deliberately excludes footage-bound
/// signals (scene grades, favorites, reviews) — those are opinions about
/// specific local clips and are meaningless elsewhere.
///
/// The file is plain JSON, small, and human-readable, so it diffs cleanly in
/// git and can be handed to another user for import.
nonisolated struct WizardBrain: Codable, Sendable {
    static let currentFormat = "clipbuilder-wizard-brain"
    static let currentVersion = 1

    struct Lesson: Codable, Sendable {
        var text: String
        var pinned: Bool
        var evidence: String
    }

    struct Category: Codable, Sendable {
        var key: String
        var label: String
        var rubric: String
        var studiedCount: Int
        /// Exemplar frames as base64 JPEG, so the brain is one self-contained file.
        var exemplarFramesBase64: [String]

        enum CodingKeys: String, CodingKey {
            case key, label, rubric
            case studiedCount = "studied_count"
            case exemplarFramesBase64 = "exemplar_frames_base64"
        }
    }

    var format = WizardBrain.currentFormat
    var version = WizardBrain.currentVersion
    var exportedAt: String
    var profileName: String
    var lessons: [Lesson]
    var tasteRubric: String
    var houseStyle: String
    var categories: [Category]

    enum CodingKeys: String, CodingKey {
        case format, version
        case exportedAt = "exported_at"
        case profileName = "profile_name"
        case lessons
        case tasteRubric = "taste_rubric"
        case houseStyle = "house_style"
        case categories
    }

    /// Assemble a brain from the current profile + lessons, inlining the
    /// exemplar frames that still exist on disk.
    static func assemble(profile: BrandProfile, lessons: [WizardLesson]) -> WizardBrain {
        let categories = profile.tasteCategories.map { category in
            Category(key: category.key,
                     label: category.label,
                     rubric: category.rubric,
                     studiedCount: category.studiedCount,
                     exemplarFramesBase64: category.exemplarFrames.compactMap { path in
                         let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                         return (try? Data(contentsOf: url))?.base64EncodedString()
                     })
        }
        return WizardBrain(exportedAt: ISO8601DateFormatter().string(from: Date()),
                           profileName: profile.profileName,
                           lessons: lessons.map {
                               Lesson(text: $0.text, pinned: $0.pinned, evidence: $0.evidence)
                           },
                           tasteRubric: profile.tasteRubric,
                           houseStyle: profile.houseStyle,
                           categories: categories)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> WizardBrain {
        let brain = try JSONDecoder().decode(WizardBrain.self, from: Data(contentsOf: url))
        guard brain.format == currentFormat else {
            throw CocoaError(.fileReadCorruptFile,
                             userInfo: [NSLocalizedDescriptionKey:
                                "Not a Wizard Brain file (format \"\(brain.format)\")."])
        }
        return brain
    }
}
