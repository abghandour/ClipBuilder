import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

struct InterviewFaceSamplingTests {
    private func roster() -> [VideoPersonRecord] {
        [VideoPersonRecord(videoID: 1, personID: 1, key: "guest", name: "Guest", descriptor: "", portraitAt: 0,
            portraitBox: .init(x: 0.34, y: 0.2, w: 0.04, h: 0.1), vip: true),
         VideoPersonRecord(videoID: 1, personID: 2, key: "host", name: "Host", descriptor: "", portraitAt: 0,
            portraitBox: .init(x: 0.52, y: 0.2, w: 0.04, h: 0.1), vip: false)]
    }

    private func video() -> VideoRecord {
        var video = Fixtures.video()
        video.width = 1920; video.height = 1080; video.duration = 40
        video.podcastLayout = PodcastLayout.singleCamera.rawValue
        return video
    }

    private func turns() -> [SpeakerTurn] {
        [SpeakerTurn(videoID: 1, start: 0, end: 15, cluster: 0, confidence: 1, personKey: "guest", tile: 0),
         SpeakerTurn(videoID: 1, start: 15, end: 22, cluster: 1, confidence: 1, personKey: "host", tile: 1),
         SpeakerTurn(videoID: 1, start: 22, end: 40, cluster: 0, confidence: 1, personKey: "guest", tile: 0)]
    }

    @Test func sampleTimesAreTheRangeStartAndEachSettledMove() {
        let times = InterviewFaceSampling.sampleTimes(video: video(), range: 10...30, turns: turns(), roster: roster())
        // Moves at 15 (host) and 22 (guest) on the source clock, each settled 0.8 s later.
        #expect(times == [10.1, 15.8, 22.8])
        #expect(InterviewFaceSampling.sampleTimes(video: video(), range: 10...10, turns: turns(), roster: roster()).isEmpty)
    }

    @Test func thinningKeepsEndsAndSpreadsEvenly() {
        let many = (0..<12).map(Double.init)
        #expect(InterviewFaceSampling.thinned(many, limit: 6) == [0, 2, 4, 7, 9, 11])
        #expect(InterviewFaceSampling.thinned(many, limit: 20) == many)
        #expect(InterviewFaceSampling.thinned(many, limit: 1) == [0])
        #expect(InterviewFaceSampling.thinned([], limit: 6).isEmpty)
    }

    @Test func mergedIsTheMeanAndIgnoresEmptyBoxes() {
        let boxes = [CGRect(x: 0.3, y: 0.2, width: 0.04, height: 0.1), CGRect(x: 0.34, y: 0.24, width: 0.08, height: 0.14), .null, .zero]
        let merged = try! #require(InterviewFaceSampling.merged(boxes))
        #expect(abs(merged.minX - 0.32) < 1e-9 && abs(merged.minY - 0.22) < 1e-9)
        #expect(abs(merged.width - 0.06) < 1e-9 && abs(merged.height - 0.12) < 1e-9)
        #expect(InterviewFaceSampling.merged([.null]) == nil)
    }

    @Test func applyingReplacesOnlySeenPeopleAndKeepsTheRest() {
        let seen = ["guest": CGRect(x: 0.4, y: 0.3, width: 0.05, height: 0.12)]
        let refined = InterviewFaceSampling.applying(faces: seen, at: 12.5, to: roster())
        #expect(refined[0].portraitBox == .init(x: 0.4, y: 0.3, w: 0.05, h: 0.12) && refined[0].portraitAt == 12.5)
        #expect(refined[1] == roster()[1])
        #expect(refined.map(\.vip) == roster().map(\.vip))
    }

    @Test func missingFileOrSinglePersonKeepsTheRoster() async {
        var video = video()
        video.path = "/nonexistent/interview.mp4"
        let same = await InterviewFaceSampling.refinedRoster(video: video, roster: roster(), range: 10...30,
                                                            turns: turns(), log: { _ in })
        #expect(same == roster())
        let one = await InterviewFaceSampling.refinedRoster(video: video, roster: [roster()[0]], range: 10...30,
                                                           turns: turns(), log: { _ in })
        #expect(one == [roster()[0]])
    }
}
