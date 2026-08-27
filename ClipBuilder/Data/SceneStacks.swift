import Foundation

/// How aggressively near-simultaneous takes collapse into one stacked card.
/// One app-wide choice, persisted under `SceneStacks.levelKey` and read via
/// `@AppStorage` on every surface that shows a filterable scene list.
nonisolated enum SceneStackLevel: String, CaseIterable, Identifiable, Sendable {
    case off
    case light
    case standard
    case aggressive

    var id: String { rawValue }

    /// The persisted raw value, defaulting to `.standard` for missing or
    /// unrecognized values (e.g. after renaming a case).
    static func from(_ raw: String) -> SceneStackLevel {
        SceneStackLevel(rawValue: raw) ?? .standard
    }

    var label: String {
        switch self {
        case .off: "Off"
        case .light: "Light"
        case .standard: "Standard"
        case .aggressive: "Aggressive"
        }
    }

    /// A stack only accepts takes STARTING within this many seconds of its
    /// first take — the size of a "moment".
    var maxStackSpan: Double {
        switch self {
        case .off: 0
        case .light: 6
        case .standard: 15
        case .aggressive: 30
        }
    }

    /// Adjacent takes chain across gaps up to this many seconds — overlap
    /// always counts as adjacent.
    var gapTolerance: Double {
        switch self {
        case .off: 0
        case .light: 1
        case .standard: 2
        case .aggressive: 4
        }
    }
}

/// Groups scenes that cover the same moment — overlapping or nearly
/// touching timestamps on the same video — into "stacks" so a 10-second
/// exchange the analyzer cut into ten takes shows as one card. Display-only:
/// the store's scene list stays flat, so clips, renders, and scene ids keep
/// resolving every scene.
nonisolated enum SceneStacks {
    /// UserDefaults key for the shared `SceneStackLevel` raw value.
    static let levelKey = "scenes.stackLevel"

    /// Partition `scenes` into stacks. Each stack's members come back in
    /// display order — the best one first (the user's pick when they made
    /// one, otherwise the AI's) — and the stacks themselves keep the input
    /// order of their earliest member, so a time-sorted grid stays
    /// time-sorted. Most stacks are singletons; `.off` yields only
    /// singletons.
    ///
    /// A stack is one *moment*, not a whole video: takes chain while they
    /// overlap or nearly touch, but only while they start within the
    /// level's span of the stack's first take. Anchoring on the first start
    /// (rather than capping the covered range) means wall-to-wall analyzer
    /// segmentation can't creep a stack across the entire video, while
    /// re-analyzed duplicates of even a long sequence (same start, batch
    /// two) still land in the same stack.
    static func group(_ scenes: [SceneRecord],
                      level: SceneStackLevel = .standard) -> [[SceneRecord]] {
        guard level != .off else { return scenes.map { [$0] } }
        var openStacks: [Int64: (members: [SceneRecord], anchor: Double, maxEnd: Double)] = [:]
        var stacksByFirstID: [Int64: [SceneRecord]] = [:]

        func close(_ stack: (members: [SceneRecord], anchor: Double, maxEnd: Double)) {
            stacksByFirstID[stack.members[0].id] = ordered(stack.members)
        }

        for scene in scenes.sorted(by: { ($0.videoID, $0.startTime) < ($1.videoID, $1.startTime) }) {
            if var open = openStacks[scene.videoID] {
                if scene.startTime <= open.maxEnd + level.gapTolerance,
                   scene.startTime < open.anchor + level.maxStackSpan {
                    open.members.append(scene)
                    open.maxEnd = max(open.maxEnd, scene.endTime)
                    openStacks[scene.videoID] = open
                    continue
                }
                close(open)
            }
            openStacks[scene.videoID] = ([scene], scene.startTime, scene.endTime)
        }
        for open in openStacks.values { close(open) }

        // Reassemble in the caller's order, keyed by each stack's earliest
        // member (the one that anchored the chain above).
        var result: [[SceneRecord]] = []
        for scene in scenes {
            if let stack = stacksByFirstID.removeValue(forKey: scene.id) {
                result.append(stack)
            }
        }
        // Stacks whose earliest member wasn't the caller-order anchor (can't
        // happen with time-sorted input, but stay total for score-sorted).
        result.append(contentsOf: stacksByFirstID.values)
        return result
    }

    /// Just the best take of every stack — for surfaces that consume a flat
    /// scene list (a wizard pool, a Generate Video source) where the other
    /// takes would only duplicate the same moment.
    static func tops(_ scenes: [SceneRecord],
                     level: SceneStackLevel = .standard) -> [SceneRecord] {
        guard level != .off else { return scenes }
        return group(scenes, level: level).map { $0[0] }
    }

    /// Stack members in display order: the user's persisted pick first, then
    /// the AI's ranking. The AI's best is NOT simply the longest — it's the
    /// same blend the Wizard shortlists by (entertainment score, crowd
    /// excitement, highlight tags, favorites, curation, grades).
    static func ordered(_ members: [SceneRecord]) -> [SceneRecord] {
        members.sorted { a, b in
            if a.stackChoice != b.stackChoice { return a.stackChoice }
            let rankA = rank(a), rankB = rank(b)
            if rankA != rankB { return rankA > rankB }
            if a.duration != b.duration { return a.duration > b.duration }
            return a.id < b.id
        }
    }

    /// The member the AI would put on top, ignoring the user's pick —
    /// flagged in the stack picker so the user can see (and return to) it.
    static func aiBest(of members: [SceneRecord]) -> SceneRecord? {
        members.max { a, b in
            let rankA = rank(a), rankB = rank(b)
            if rankA != rankB { return rankA < rankB }
            if a.duration != b.duration { return a.duration < b.duration }
            return a.id > b.id
        }
    }

    /// Mirrors WizardEngine.shortlistScenes' rank(_:) so "best of the stack"
    /// and "worth planning with" agree on what good footage is.
    static func rank(_ scene: SceneRecord) -> Double {
        var rank = scene.score ?? scene.excitement.map { $0 * 10 } ?? -1
        if scene.tags.contains(where: { $0 == "highlight" || $0.hasPrefix("highlight:") }) { rank += 5 }
        if scene.favorite { rank += 4 }
        if scene.curated { rank += 2 }
        if let grade = scene.gradeAverage, scene.gradeCount > 0 { rank += grade - 3 }
        if scene.tags.contains("low-quality") { rank -= 4 }
        return rank
    }
}
