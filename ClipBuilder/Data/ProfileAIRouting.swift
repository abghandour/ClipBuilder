import Foundation

/// A profile's shared recommendation. Provider settings stay on each Mac.
nonisolated struct ProfileAIRouting: Codable, Sendable, Hashable {
    var tasks: [String: String] = [:]
    var taskModels: [String: String] = [:]

    init(tasks: [String: String] = [:], taskModels: [String: String] = [:]) {
        self.tasks = tasks
        self.taskModels = taskModels
    }

    enum CodingKeys: String, CodingKey {
        case tasks
        case taskModels = "task_models"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decodeIfPresent([String: String].self, forKey: .tasks) ?? [:]
        taskModels = try container.decodeIfPresent([String: String].self, forKey: .taskModels) ?? [:]
    }
}
