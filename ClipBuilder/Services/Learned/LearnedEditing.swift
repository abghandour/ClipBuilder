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
    /// Carries one action's effect onto a possibly newer profile: a dismiss
    /// adds its id, and every action bumps the lessons timestamp. Nothing else
    /// from the edited snapshot is copied, so a concurrent Restore survives.
    static func applyDelta(_ action: LessonAction, id: String, from edited: BrandProfile,
                           to current: BrandProfile) -> BrandProfile {
        var profile = current
        if case .dismiss = action { profile.learnedSharing.dismissedLessons.insert(id) }
        profile.learnedSharing.updatedAt["lessons"] = edited.learnedSharing.updatedAt["lessons"]
        return profile
    }
    /// Undo a dismissal; the row was never deleted, so it reappears in the document.
    static func restoreLesson(_ id: String, profile: BrandProfile, now: Date = Date()) -> BrandProfile {
        var profile = profile
        guard profile.learnedSharing.dismissedLessons.remove(id) != nil else { return profile }
        profile.learnedSharing.updatedAt["lessons"] = now
        LearnedCache.invalidate(profile: profile.profileName)
        return profile
    }
    /// Edit what a category says, never what it is: key, frames and study
    /// count identify it in highlight tags and Wizard selections.
    static func editCategory(_ key: String, label: String, rubric: String, profile: BrandProfile,
                             now: Date = Date()) -> BrandProfile {
        var profile = profile
        guard let index = profile.tasteCategories.firstIndex(where: { $0.key == key }) else { return profile }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.tasteCategories[index].label = label.isEmpty ? profile.tasteCategories[index].label : label
        profile.tasteCategories[index].rubric = rubric.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.learnedSharing.updatedAt["taste"] = now
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
