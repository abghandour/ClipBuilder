import Foundation

nonisolated struct AssetSyncPlan: Sendable {
    enum Operation: String, CaseIterable, Sendable {
        case createLocalFolder, createDriveFolder, upload, download, skip, replaceInDrive, replaceLocal, conflict
    }
    struct Action: Equatable, Sendable {
        var operation: Operation
        var path: String
        var local: AssetSyncEntry?
        var remote: AssetSyncEntry?
    }
    var actions: [Action] = []
    var reports: [String] = []
}
