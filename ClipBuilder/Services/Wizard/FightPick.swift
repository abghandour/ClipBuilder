import Foundation

/// One stretch of a fight the user picked from its scored actions in AI
/// Wizard Express. Stored per video; its scene is created only when the
/// picks become selections.
nonisolated struct FightPick: Identifiable, Sendable, Equatable {
    var id: Int64
    var videoID: Int64
    var position: Int
    var start: Double
    var end: Double
    var originalStart: Double
    var originalEnd: Double
    /// The scored fight events the pick was built from, in time order.
    var eventIDs: [Int64]
    var sceneID: Int64?

    var range: ClosedRange<Double> { start...max(start, end) }
    var originalRange: ClosedRange<Double> { originalStart...max(originalStart, originalEnd) }
}

/// The Fight metrics review stays available after its picks become selections.
nonisolated struct MiniWizardFight: Sendable {
    var actions: [MiniWizardFightRules.Action]
    var picks: [FightPick]
    /// Fighter display names by person key.
    var names: [String: String]
}
