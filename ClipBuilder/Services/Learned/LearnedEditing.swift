import Foundation

nonisolated enum LearnedEditing {
    enum LessonAction: Sendable { case pin(Bool), dismiss, rewrite(String) }
    static func editLesson(_ id: String, action: LessonAction, profile: BrandProfile,
                           database: Database, now: Date = Date()) async throws -> BrandProfile {
        var profile = profile
        guard let lesson = try await database.fetchLessons().first(where: { $0.learnedID == id }) else {
            throw LearnedRedaction.Failure.invalidDocument
        }
        switch action {
        case .pin(let value): try await database.updateLesson(id: lesson.id, text: lesson.text, pinned: value)
        case .rewrite(let text): try await database.updateLesson(id: lesson.id, text: text, pinned: lesson.pinned)
        case .dismiss: profile.learnedSharing.dismissedLessons.insert(id)
        }
        profile.learnedSharing.updatedAt["lessons"] = now
        LearnedCache.invalidate(profile: profile.profileName)
        return profile
    }
    static func dropCategory(_ id: String, profile: BrandProfile, now: Date = Date()) -> BrandProfile {
        var profile = profile
        profile.tasteCategories.removeAll { $0.key == id }
        profile.learnedSharing.updatedAt["taste"] = now
        LearnedCache.invalidate(profile: profile.profileName)
        return profile
    }
}
