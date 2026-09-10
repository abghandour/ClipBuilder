import Foundation
import Testing
@testable import Clip_Builder

struct ReelModelEligibilityTests {
    private func store(_ temp: TempDirectory) -> ReelModelStore {
        ReelModelStore(root: temp.url.appendingPathComponent("models"), reports: temp.url.appendingPathComponent("reports"))
    }
    private func report(_ store: ReelModelStore, passed: Bool = true, local: Bool = true,
                        traits: Int = ReelTraits.version, hash: String? = nil) throws -> ReelModelEvaluation {
        let artifact = store.artifact(.ranker)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: artifact.appendingPathComponent("weights.bin"))
        return ReelModelEvaluation(item: .ranker, version: 1, traitsVersion: traits, date: Date(), origin: nil,
                                   trainingCount: 10, holdoutCount: 3, metrics: [:], baseline: 0.5, passed: passed,
                                   importance: [:], artifactHash: try hash ?? ReelModelStore.hash(artifact),
                                   localEvaluation: local)
    }
    @Test func truthTable() throws {
        let temp = try TempDirectory()
        let store = store(temp)
        #expect(store.eligibility(.ranker) == .notEvaluated)
        try store.save(report(store, passed: false))
        #expect(store.eligibility(.ranker) == .notPassed)
        try store.save(report(store, local: false))
        #expect(store.eligibility(.ranker) == .needsLocalEvaluation)
        try store.save(report(store, traits: ReelTraits.version - 1))
        #expect(store.eligibility(.ranker) == .traitsOutdated)
        try store.save(report(store, hash: "stale"))
        #expect(store.eligibility(.ranker) == .artifactChanged)
        try store.save(report(store))
        #expect(store.eligibility(.ranker) == .eligible)
    }
    @Test func effectiveNeedsRequestEligibilityAndMasterSwitch() throws {
        let temp = try TempDirectory()
        let store = store(temp)
        try store.save(report(store))
        var config = AIConfig()
        config.preferOnDevice = false
        #expect(ReelModelState.make(.ranker, store: store, config: config).effective == false)
        config.onDeviceOverrides[ReelModelItem.ranker.rawValue] = true
        let requested = ReelModelState.make(.ranker, store: store, config: config)
        #expect(requested.requested && !requested.effective && requested.blockedByMasterSwitch)
        config.preferOnDevice = true
        #expect(ReelModelState.make(.ranker, store: store, config: config).effective)
    }
}
