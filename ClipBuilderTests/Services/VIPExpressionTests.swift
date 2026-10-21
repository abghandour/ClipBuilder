import Testing
@testable import Clip_Builder

struct VIPExpressionTests {
    @Test func maximaAboveMedianRespectGapAndStrength() {
        let samples: [(time: Double, score: Double)] = (0...14).map { time in
            var score = 1.0
            if time == 4 { score = 5 }
            else if time == 2 || time == 10 { score = 3 }
            return (time: Double(time), score: score)
        }
        let track = VIPExpression.Track(tile: 1, samples: samples)
        #expect(VIPExpression.peaks(track) == [4, 10])
        #expect(VIPExpression.peaks(track, minimumGap: 1) == [2, 4, 10])
    }

    @Test func flatTracksAndSubthresholdMotionHaveNoPeaks() {
        for value in [0.0, 1.0, 20.0] {
            let track = VIPExpression.Track(tile: 0, samples: (0...10).map { (Double($0), value) })
            #expect(VIPExpression.peaks(track).isEmpty)
        }
        #expect(VIPExpression.peaks(.init(tile: 0, samples: [(0, 1), (1, 1.8), (2, 1)])).isEmpty)
        #expect(VIPExpression.peaks(.init(tile: 0, samples: [])).isEmpty)
    }

    @Test func normalizationRemovesFeedMotionBiasAndNoise() {
        let quiet = [(time: 0.0, score: 2.0), (time: 1.0, score: 8.0), (time: 2.0, score: 2.0)]
        let fidget = quiet.map { (time: $0.time, score: $0.score * 10) }
        #expect(VIPExpressionScore.normalized(quiet).map(\.score) == VIPExpressionScore.normalized(fidget).map(\.score))
        let noise = VIPExpressionScore.normalized([(0, 0), (1, 0.01), (2, 0)])
        #expect(VIPExpression.peaks(.init(tile: 0, samples: noise)).isEmpty)
        #expect(VIPExpressionScore.change([2, 4], from: [0, 0]) == 3)
        #expect(VIPExpressionScore.change([], from: []) == 0)
    }

    @Test func peaksFromDifferentFeedsAreRankedByScore() {
        let tracks = [VIPExpression.Track(tile: 0, samples: [(0, 1), (1, 3), (2, 1)]),
                      VIPExpression.Track(tile: 1, samples: [(2, 1), (3, 5), (4, 1)])]
        #expect(VIPExpression.rankedPeaks(tracks).map(\.tile) == [1, 0])
    }
}
