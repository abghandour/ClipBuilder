import Testing
@testable import Clip_Builder

@Suite("Batch comparison")
struct BatchComparisonTests {
    private func scene(_ id: Int64, run: Int64, _ start: Double, _ end: Double,
                       tags: [String] = ["striking"], grade: Double? = nil, favorite: Bool = false) -> SceneRecord {
        var scene = Fixtures.scene(id: id, start: start, end: end)
        scene.runID = run
        scene.tags = tags
        scene.favorite = favorite
        if let grade { scene.gradeAverage = grade; scene.gradeCount = 1; scene.lastGrade = Int(grade) }
        return scene
    }

    @Test("moments the batches share, moments only one found, coverage and the graded-good share")
    func compare() {
        let scenes = [
            // Both batches found the opening exchange (same start, batch 2 cut it shorter).
            scene(1, run: 1, 0, 10, tags: ["striking", "person:ann"], grade: 5),
            scene(2, run: 2, 0, 8, tags: ["striking"]),
            // Only batch 1 saw the knockdown.
            scene(3, run: 1, 30, 40, tags: ["knockdown", "person:ann"], grade: 1, favorite: true),
            // Only batch 2 saw the walkout; it overlaps nothing.
            scene(4, run: 2, 60, 70, tags: ["walkout"], grade: 5),
            // Ignored scenes are left out entirely.
            { var s = scene(5, run: 2, 80, 90); s.ignored = true; return s }(),
            // A third batch's scene is not part of this comparison.
            scene(6, run: 3, 0, 10),
        ]
        let comparison = BatchComparison.compare(runIDs: [1, 2], scenes: scenes, duration: 100)
        #expect(comparison.shared.count == 1)
        #expect(comparison.shared[0].runIDs == [1, 2])
        #expect(comparison.unique(to: 1).map(\.id) == [3])
        #expect(comparison.unique(to: 2).map(\.id) == [4])
        #expect(Set(comparison.allUnique.map(\.id)) == [3, 4])

        let one = try! #require(comparison.metrics[1])
        #expect(one.sceneCount == 2)
        #expect(one.coverage == 0.2)
        #expect(one.averageLength == 10)
        #expect(one.tagCount == 2)
        #expect(one.peopleCount == 1)
        #expect(one.favorites == 1)
        #expect(one.uniqueCount == 1 && one.sharedCount == 1)
        #expect(one.gradedCount == 2 && one.goodCount == 1)
        #expect(one.goodShare == 0.5)

        let two = try! #require(comparison.metrics[2])
        #expect(two.sceneCount == 2)
        #expect(two.coverage == 0.18)
        #expect(two.goodShare == 1)
        #expect(two.tagCount == 2 && two.peopleCount == 0)
    }

    @Test("matching is the comparison's own: chapters of one topic match across batches")
    func chaptersMatch() {
        let scenes = [
            scene(1, run: 1, 0, 120, tags: ["podcast", "chapter"]),
            scene(2, run: 2, 0, 118, tags: ["podcast", "chapter"]),
            scene(3, run: 1, 200, 210), scene(4, run: 2, 201, 209),
        ]
        let comparison = BatchComparison.compare(runIDs: [1, 2], scenes: scenes, duration: 300)
        #expect(comparison.shared.count == 2)
        #expect(comparison.allUnique.isEmpty)
    }

    @Test("covered seconds merge overlapping and touching ranges")
    func coverage() {
        let scenes = [scene(1, run: 1, 0, 10), scene(2, run: 1, 5, 12), scene(3, run: 1, 12, 15), scene(4, run: 1, 20, 21)]
        #expect(BatchComparison.coveredSeconds(scenes) == 16)
        #expect(BatchComparison.coveredSeconds([]) == 0)
    }
}
