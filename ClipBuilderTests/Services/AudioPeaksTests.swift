import Testing
@testable import Clip_Builder

struct AudioPeaksTests {
    @Test("Samples fold into one absolute peak per millisecond bin, timed from the first sample")
    func binning() {
        // 16 kHz: 16 samples per bin.
        var samples = [Float](repeating: 0.01, count: 48)
        samples[3] = -0.5
        samples[20] = 0.25
        samples[47] = 1.5
        let peaks = AudioPeaks.binned(samples, sampleRate: 16_000, start: 10)
        #expect(peaks.levels == [0.5, 0.25, 1])
        #expect(abs(peaks.span.lowerBound - 10) < 1e-9 && abs(peaks.span.upperBound - 10.003) < 1e-9)
        #expect(peaks.covers(10.001...10.002) && !peaks.covers(9.9...10.002))
        #expect(AudioPeaks.binned([], sampleRate: 16_000, start: 1).isEmpty)
    }

    @Test("Columns take the loudest bin they cover and scale to the window's loudest, never above a whisper")
    func columns() {
        let peaks = AudioPeaks(span: 0...1, levels: [0.1, 0.4, 0.2, 0.2])
        #expect(peaks.columns(2, window: 0...1) == [1, 0.5])
        #expect(peaks.columns(1, window: 0.5...1) == [1])
        let quiet = AudioPeaks(span: 0...1, levels: [0.01, 0.02])
        let scaled = quiet.columns(2, window: 0...1)
        #expect(scaled.count == 2 && abs(scaled[0] - 0.2) < 1e-5 && abs(scaled[1] - 0.4) < 1e-5)
        #expect(peaks.columns(0, window: 0...1).isEmpty)
    }

    @Test("Time and position map both ways, clamped to the view")
    func mapping() {
        #expect(AudioPeaks.x(for: 11, in: 10...14, width: 200) == 50)
        #expect(AudioPeaks.time(forX: 150, in: 10...14, width: 200) == 13)
        #expect(AudioPeaks.time(forX: -20, in: 10...14, width: 200) == 10)
        #expect(AudioPeaks.time(forX: 500, in: 10...14, width: 200) == 14)
    }

    @Test("The window centres on the edge and slides back inside the recording")
    func window() {
        #expect(AudioPeaks.window(center: 30, halfWidth: 2, limits: 0...60) == 28...32)
        #expect(AudioPeaks.window(center: 0.5, halfWidth: 2, limits: 0...60) == 0...4)
        #expect(AudioPeaks.window(center: 59.5, halfWidth: 2, limits: 0...60) == 56...60)
        // A recording shorter than the window keeps the plain window.
        #expect(AudioPeaks.window(center: 1, halfWidth: 2, limits: 0...3) == -1...3)
    }

    @Test("A boundary drag moves only its own edge, and the speaker is the line playing there")
    func boundaryHelpers() {
        #expect(RangeBoundaryWaveforms.range(10...20, edge: .start, to: 12) == 12...20)
        #expect(RangeBoundaryWaveforms.range(10...20, edge: .end, to: 18.5) == 10...18.5)
        let lines = [
            TranscriptQATrim.Line(id: 0, start: 0, end: 5, speaker: "Alice", words: []),
            TranscriptQATrim.Line(id: 1, start: 6, end: 9, speaker: "Marcello", words: []),
        ]
        #expect(RangeBoundaryWaveforms.speaker(at: 2, lines: lines) == "Alice")
        #expect(RangeBoundaryWaveforms.speaker(at: 5.8, lines: lines) == "Marcello")
        #expect(RangeBoundaryWaveforms.speaker(at: 20, lines: lines) == "Marcello")
        #expect(RangeBoundaryWaveforms.speaker(at: 1, lines: []) == nil)
    }
}
