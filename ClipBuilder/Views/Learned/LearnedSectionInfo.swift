import Foundation

/// Static, user-facing explanations for everything the AI Lessons page shows:
/// what a section is, which feature reads it, and where it is edited. Kept in
/// one place so the page, its tests, and the guide agree.
nonisolated enum LearnedSectionInfo {
    /// A feature that reads learned data. The label is what the page shows.
    enum Consumer: String, CaseIterable, Sendable {
        case wizardPlan, captions, critic, analysis, performanceLessons, research

        var label: String {
            switch self {
            case .wizardPlan: "Wizard plans"
            case .captions: "Captions and hashtags"
            case .critic: "Reel critic"
            case .analysis: "Analysis tagging"
            case .performanceLessons: "Performance lessons"
            case .research: "Fight research"
            }
        }
        var symbol: String {
            switch self {
            case .wizardPlan: "wand.and.stars"
            case .captions: "text.quote"
            case .critic: "checkmark.seal"
            case .analysis: "tag"
            case .performanceLessons: "chart.line.uptrend.xyaxis"
            case .research: "magnifyingglass"
            }
        }
    }

    /// Where a section's underlying fields are edited today. `page` means the
    /// AI Lessons page itself; `settings` opens a Settings tab.
    enum EditLocation: Equatable, Sendable {
        case page
        case settings(tab: String, title: String)
        case project(title: String)

        var label: String {
            switch self {
            case .page: "Edit here"
            case .settings(_, let title): "Change in Settings › \(title)"
            case .project(let title): "Change in \(title)"
            }
        }
    }

    /// A consumer plus the condition under which it reads this section.
    struct Use: Sendable, Identifiable {
        var consumer: Consumer
        var qualifier: String
        var id: String { consumer.rawValue }
    }

    struct Entry: Sendable {
        var title: String
        var purpose: String
        var usedBy: [Use]
        /// Zero or more places to change the underlying fields.
        var editLocations: [EditLocation]
        /// Shown when there is no edit location, or when the section is empty.
        var readOnlyReason: String
        var emptyNote: String = ""

        var editLocation: EditLocation? { editLocations.first }
    }

    static func entry(_ kind: LearnedPreferences.Kind) -> Entry {
        switch kind {
        case .style:
            .init(title: "Style",
                  purpose: "How your reels are cut: house style, hook style, layout, pacing and caption languages.",
                  usedBy: [.init(consumer: .wizardPlan, qualifier: "House style on every plan. Hook and layout only while Learned editing defaults is on."),
                           .init(consumer: .critic, qualifier: "House style."),
                           .init(consumer: .captions, qualifier: "Caption languages.")],
                  editLocations: [.settings(tab: "taste", title: "Taste › House Style"),
                                  .settings(tab: "profile", title: "Profile › Brand Kit (languages)"),
                                  .settings(tab: "profile", title: "Profile › Default Output (pacing)")],
                  readOnlyReason: "")
        case .taste:
            .init(title: "Taste",
                  purpose: "What a keeper moment looks like: the rubric and per-type categories, with example frames.",
                  usedBy: [.init(consumer: .wizardPlan, qualifier: "The rubric or category chosen by the run's taste preset; example frames are attached as images."),
                           .init(consumer: .critic, qualifier: "The rubric only."),
                           .init(consumer: .analysis, qualifier: "The rubric adds the highlight tag; each category with a rubric adds highlight:<category>.")],
                  editLocations: [.settings(tab: "taste", title: "Taste")],
                  readOnlyReason: "")
        case .lessons:
            .init(title: "Lessons",
                  purpose: "Rules distilled from your reel reviews or written by hand. Pinned rules survive re-distilling.",
                  usedBy: [.init(consumer: .wizardPlan, qualifier: "Every plan, minus dismissed rules. A shared copy of the same rule replaces yours when newer. Local and shared learning together are capped at 12,000 characters.")],
                  editLocations: [.page],
                  readOnlyReason: "")
        case .vocabulary:
            .init(title: "Vocabulary",
                  purpose: "Your tag schema and pinned hashtags.",
                  usedBy: [.init(consumer: .analysis, qualifier: "Tags to assign. The built-in schema is used when yours is empty."),
                           .init(consumer: .captions, qualifier: "Pinned hashtags seed the caption's hashtags when the caption uses local hashtags (up to seven candidates)."),
                           .init(consumer: .wizardPlan, qualifier: "Listed as learned vocabulary once a Google Drive home is set.")],
                  editLocations: [.settings(tab: "profile", title: "Profile › Tag Schema"),
                                  .settings(tab: "profile", title: "Profile › Brand Kit")],
                  readOnlyReason: "",
                  emptyNote: "Using the built-in vocabulary.")
        case .benchmarks:
            .init(title: "Benchmarks",
                  purpose: "Measured from your Instagram insights: duration sweet spot, engagement rates, posting slots, hashtag lift.",
                  usedBy: [.init(consumer: .wizardPlan, qualifier: "Planner targets."),
                           .init(consumer: .critic, qualifier: "Forecasts against this account's audience."),
                           .init(consumer: .performanceLessons, qualifier: "Input to performance-derived rules."),
                           .init(consumer: .captions, qualifier: "Hashtag lift, hot subjects and caption length.")],
                  editLocations: [],
                  readOnlyReason: "Computed from imported Instagram insights. Refresh after a new import.")
        case .people:
            .init(title: "People",
                  purpose: "Registered people and how to recognise them.",
                  usedBy: [.init(consumer: .wizardPlan, qualifier: "Names and descriptors in every plan."),
                           .init(consumer: .captions, qualifier: "People matching the reel's tags become hashtag candidates when the caption uses local hashtags.")],
                  editLocations: [.project(title: "People")],
                  readOnlyReason: "")
        case .research:
            .init(title: "Research",
                  purpose: "Fight research summaries and saved query plans.",
                  usedBy: [.init(consumer: .wizardPlan, qualifier: "Your research: when fight research is on, scoped to the selected footage. Shared research: in the shared block when a contributor turns it on."),
                           .init(consumer: .captions, qualifier: "Sentiment and story angle.")],
                  editLocations: [],
                  readOnlyReason: "Saved from the Fight Research sheet.")
        }
    }

    /// Help text for the row-level signals. Shown as hover help.
    static let pinnedHelp = "Pinned: never replaced when rules are re-distilled from reviews."
    static let evidenceHelp = "Evidence: which reviews, studies or imports produced this."
    static let mergeHelp = "When another Mac shares the same entry, the newer one wins. Your own house style, hook style, layout, pacing, taste rubric and benchmark summary always win over shared ones."
    static let shareHelp = "What leaves this Mac when you publish. These switches never change what this Mac uses; each feature still applies its own conditions. People and research stay private unless you turn them on. Trained models are published separately."
    static let noHomeHelp = "Choose a Google Drive home in Settings › Google Drive to share learning between Macs."
}

/// Plain-language descriptions for the trained models.
nonisolated enum ReelModelInfo {
    struct Entry: Sendable {
        var title: String
        var predicts: String
        var trainedFrom: String
        var whenEnabled: String
    }

    static func entry(_ item: ReelModelItem) -> Entry {
        switch item {
        case .outcome:
            .init(title: "Outcome model",
                  predicts: "How much a reel will outperform your account's median, as a number.",
                  trainedFrom: "Your published reels and imported Instagram insights.",
                  whenEnabled: "The Wizard logs a predicted lift for each candidate reel it renders, and the critic reports it.")
        case .ranker:
            .init(title: "Clip ranker",
                  predicts: "For each candidate clip, whether you would keep it.",
                  trainedFrom: "Scene grades and favorites, per-clip review verdicts, and accepted or rejected edit proposals.",
                  whenEnabled: "Clip selection starts from the ranker's keep scores before the model refines it.")
        case .taste:
            .init(title: "Taste similarity",
                  predicts: "How visually similar a frame is to your taste exemplars.",
                  trainedFrom: "Exemplar frames from taste studies plus frames from your best-performing reels.",
                  whenEnabled: "The reel critic adds on-device similarity to your exemplars to its verdict.")
        }
    }
}
