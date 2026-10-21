import Foundation
import Testing
@testable import Clip_Builder

/// A podcast cut whose main track holds several pieces (VIP feed changes) is
/// one extracted file: assembly must give that file the whole cut's length.
struct WizardPodcastCutAssemblyTests {
    @Test func piecesOfOneCutShareTheExtractedFile() throws {
        let scene = Fixtures.scene(id: 7, start: 100, end: 169)
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 100, end: 169)], transitions: [])
        var cut = TimelineDocument()
        for (start, duration) in [(0.0, 40.0), (40.0, 29.0)] {
            var piece = TimelineClip()
            piece.videoFile = scene.videoPath
            piece.sceneID = scene.id
            piece.sourceStart = 100 + start
            piece.sourceEnd = 100 + start + duration
            piece.startTime = start
            piece.duration = duration
            piece.track = 0
            cut.videoTrack.append(piece)
        }
        let document = WizardEngine.timelineDocument(from: plan, sceneMap: [scene.id: scene], podcastCuts: [0: cut])
        let pieces = document.videoTrack.filter { $0.track == 0 }
        #expect(pieces.count == 2)
        #expect(Set(pieces.map(\.originKey)).count == 1)

        let prepared = WizardEngine.preparedDocument(from: document,
            clipURLs: [URL(fileURLWithPath: "/tmp/extracted-7.mp4")], transitions: [])
        let main = prepared.videoTrack.filter { $0.track == 0 && !$0.isCutaway }
        #expect(main.count == 1)
        #expect(main.first?.duration == 69)
        #expect(main.first?.startTime == 0)
        #expect(main.first?.sourceEnd == 69)
    }

    @Test func separateCutsStillPairOneFileEach() throws {
        let a = Fixtures.scene(id: 1, start: 0, end: 10), b = Fixtures.scene(id: 2, start: 20, end: 25)
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: 1, start: 0, end: 10),
                                         Fixtures.planClip(sceneID: 2, start: 20, end: 25)], transitions: ["fade"])
        let document = WizardEngine.timelineDocument(from: plan, sceneMap: [1: a, 2: b])
        let prepared = WizardEngine.preparedDocument(from: document,
            clipURLs: [URL(fileURLWithPath: "/tmp/1.mp4"), URL(fileURLWithPath: "/tmp/2.mp4")], transitions: ["fade"])
        let main = prepared.videoTrack.filter { $0.track == 0 }
        #expect(main.map(\.duration) == [10, 5])
        #expect(main.map(\.startTime) == [0, 10])
    }
}
