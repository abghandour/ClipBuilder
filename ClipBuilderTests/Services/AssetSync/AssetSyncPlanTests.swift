import Testing

@testable import Clip_Builder

struct AssetSyncPlanTests {
    @Test func noDestructiveOperationExists() {
        let operations = Set(AssetSyncPlan.Operation.allCases.map(\.rawValue))
        #expect(
            operations == [
                "createLocalFolder", "createDriveFolder", "upload", "download", "skip", "replaceInDrive",
                "replaceLocal", "conflict",
            ])
    }
}
