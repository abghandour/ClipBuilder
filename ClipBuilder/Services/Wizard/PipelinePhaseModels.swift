import Foundation

/// Model routing for the rows in the Wizard Pipeline sheet, in run order.
nonisolated enum PipelinePhase: CaseIterable, Sendable {
    case detectPeople
    case transcribe
    case analyze
    case fightScoring
    case fightResearch
    case proposeNames
    case curate
    case framing
    case generate
    case critique
    case coverFrame

    func aiTasks(recipe: ReelRecipe, useBRoll: Bool, brollInstructions: String) -> [String] {
        let tasks: [String]
        switch self {
        case .detectPeople: tasks = [AITask.people.rawValue]
        case .transcribe, .framing: tasks = []
        // DispatchOperation.analyze.aiTasks, with the separate people row removed.
        case .analyze: tasks = [AITask.analysis.rawValue, AITask.exchanges.rawValue]
        // scoreFightAction uses callThinningFrames' default task, .analysis.
        case .fightScoring: tasks = [AITask.analysis.rawValue]
        case .fightResearch: tasks = [AITask.fightResearch.rawValue]
        case .proposeNames: tasks = [AITask.naming.rawValue]
        case .curate: tasks = [AITask.curate.rawValue]
        case .generate:
            tasks = WizardFormPlan(recipe: recipe).models(useBRoll: useBRoll, instructions: brollInstructions)
                .filter { $0 != AITask.critique.rawValue }
        case .critique: tasks = [AITask.critique.rawValue]
        case .coverFrame: tasks = [AITask.cover.rawValue]
        }
        var seen = Set<String>()
        return tasks.filter { AICatalog.tasks.contains($0) && seen.insert($0).inserted }
    }

    var onDeviceEngine: String? {
        switch self {
        case .transcribe: return "Apple Speech"
        case .framing: return "Apple Vision"
        default: return nil
        }
    }
}
