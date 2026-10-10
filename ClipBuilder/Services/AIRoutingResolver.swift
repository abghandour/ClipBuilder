import Foundation

nonisolated enum AIRoutingSource: Equatable {
    case localOverride, team, catalogDefault
}

nonisolated enum AIRoutingFlag: String, Equatable {
    case recommended = "★ Recommended"
    case team = "Team"
    case custom = "Custom"
}

/// Resolve routing without changing the local settings or materializing defaults.
nonisolated enum AIRoutingResolver {
    static func effectiveConfig(local: AIConfig, team: ProfileAIRouting?) -> AIConfig {
        var effective = local
        effective.tasks = team?.tasks ?? [:]
        effective.taskModels = team?.taskModels ?? [:]
        for (task, provider) in local.tasks {
            effective.tasks[task] = provider
            // Assigning nil removes the team model: overrides always win as a pair.
            effective.taskModels[task] = local.taskModels[task]
        }
        return effective
    }

    static func source(task: String, local: AIConfig, team: ProfileAIRouting?) -> AIRoutingSource {
        if local.tasks[task] != nil { return .localOverride }
        if team?.tasks[task] != nil { return .team }
        return .catalogDefault
    }

    /// Match AIService's configured pair, including its routing-task fallback.
    static func choice(task: String, local: AIConfig, team: ProfileAIRouting?) -> (provider: String, model: String) {
        let config = effectiveConfig(local: local, team: team)
        let provider = config.tasks[task].flatMap { AICatalog.provider($0) == nil ? nil : $0 }
            ?? AICatalog.taskDefaults[task] ?? "claude"
        let routeModel = task == "route"
            ? AICatalog.recommendedChains[task]?.first(where: { $0.provider == provider })?.model : nil
        let model = config.taskModels[task].flatMap { $0.isEmpty ? nil : $0 }
            ?? routeModel
            ?? config.providers[provider]?.model.flatMap { $0.isEmpty ? nil : $0 }
            ?? AICatalog.provider(provider)?.defaultModel ?? ""
        return (provider, model)
    }

    static func flag(task: String, local: AIConfig, team: ProfileAIRouting?) -> AIRoutingFlag? {
        if choice(task: task, local: local, team: team) == AICatalog.topRecommended(task: task) {
            return .recommended
        }
        switch source(task: task, local: local, team: team) {
        case .team: return .team
        case .localOverride: return .custom
        case .catalogDefault: return nil
        }
    }
}
