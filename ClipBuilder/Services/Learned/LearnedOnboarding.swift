import Foundation

/// What feeds the Wizard for this profile, judged by explicit predicates
/// rather than section counts (a new profile already has a Style item from
/// its default caption language).
nonisolated struct LearnedOnboarding: Equatable, Sendable {
    enum Step: String, CaseIterable, Sendable, Identifiable {
        case houseStyle, tasteRubric, reviews, rules, insights, people
        var id: String { rawValue }

        var title: String {
            switch self {
            case .houseStyle: "Write a house style"
            case .tasteRubric: "Write a taste rubric"
            case .reviews: "Review reels in the Library"
            case .rules: "Distill or add rules"
            case .insights: "Import Instagram insights"
            case .people: "Register people"
            }
        }
        var detail: String {
            switch self {
            case .houseStyle: "What all your reels have in common. Or distill it from analyzed reels in Settings › Taste."
            case .tasteRubric: "What a keeper moment looks like. Or study sample reels in Settings › Taste."
            case .reviews: "Thumbs and reasons on finished reels are what distilling turns into rules. A few reviews are enough to start."
            case .rules: "Rules apply to every plan. Pinned rules survive re-distilling."
            case .insights: "Benchmarks, posting slots and hashtag lift come from your account's insights."
            case .people: "Named people let the Wizard and captions refer to who is on screen."
            }
        }
    }

    var done: Set<Step>
    var reviewCount: Int

    var completed: Int { done.count }
    var total: Int { Step.allCases.count }
    var isEmpty: Bool { done.isEmpty }
    var isComplete: Bool { done.count == total }

    static func make(profile: BrandProfile, lessons: [WizardLesson], people: [PersonRecord],
                     reviews: Int, benchmarks: AccountBenchmarks?) -> LearnedOnboarding {
        var done: Set<Step> = []
        if !profile.houseStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { done.insert(.houseStyle) }
        if !profile.tasteRubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { done.insert(.tasteRubric) }
        if reviews > 0 { done.insert(.reviews) }
        if lessons.contains(where: { lesson in
            let id = lesson.learnedID.isEmpty ? LearnedPreferences.stableID(lesson.text) : lesson.learnedID
            return !profile.learnedSharing.dismissedLessons.contains(id)
        }) { done.insert(.rules) }
        if (benchmarks?.reelCount ?? 0) > 0 { done.insert(.insights) }
        if !people.isEmpty { done.insert(.people) }
        return .init(done: done, reviewCount: reviews)
    }
}
