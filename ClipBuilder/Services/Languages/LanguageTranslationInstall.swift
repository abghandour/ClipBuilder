import Foundation

/// A view supplies TranslationSession; AppJobs owns the lifetime and cancellation.
nonisolated struct LanguageTranslationInstall: Equatable, Sendable, Identifiable {
    let id: UUID
    let projectID: Int64
    let generation: Int
    var pending: [LanguageAsset]
    var current: LanguageAsset?
    var failure: String?

    var finished: Bool { pending.isEmpty && current == nil }
}
