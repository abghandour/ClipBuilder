import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@Suite("Wizard stage timings")
struct WizardTimingTests {
    @Test func linesRoundTripAndOtherLinesAreIgnored() {
        let line = WizardTiming.line("extract clips", seconds: 12.3456)
        #expect(line == "TIMING:extract clips=12.346")
        let parsed = WizardTiming.parse(line)
        #expect(parsed?.stage == "extract clips")
        #expect(parsed.map { abs($0.seconds - 12.346) < 0.0005 } == true)
        #expect(WizardTiming.parse("Extracting clip 1/3") == nil)
        #expect(WizardTiming.parse("TIMING:=1") == nil)
        #expect(WizardTiming.parse("TIMING:nothing") == nil)
        #expect(WizardTiming.parse("TIMING:x=abc") == nil)
        #expect(WizardTiming.line("render", seconds: -1) == "TIMING:render=0.000")
        #expect(WizardTiming.line("render", .milliseconds(1500)) == "TIMING:render=1.500")
    }

    @Test func displayAndFormat() {
        #expect(WizardTiming.format(0.04) == "0.0s")
        #expect(WizardTiming.format(12.34) == "12.3s")
        #expect(WizardTiming.format(65.2) == "1m 05s")
        #expect(WizardTiming.format(3600) == "60m 00s")
        #expect(WizardTiming.display("TIMING:compositor=15.04") == "⏱ compositor 15.0s")
        #expect(WizardTiming.display("Video complete!") == nil)
        #expect(LogRelay.displayText("TIMING:compositor=15.04") == "⏱ compositor 15.0s")
        #expect(LogRelay.displayText("PROGRESS:1\nTIMING:a=1\nplain") == "⏱ a 1.0s\nplain")
    }

    @Test func measureReportsTimeEvenWhenTheBodyThrows() async throws {
        let lines = Mutex<[String]>([])
        let value = try await WizardTiming.measure("quick", emit: { line in lines.withLock { $0.append(line) } }) { 7 }
        #expect(value == 7)
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await WizardTiming.measure("failing", emit: { line in lines.withLock { $0.append(line) } }) {
                try await Task.sleep(for: .milliseconds(20))
                throw Boom()
            }
        }
        let stages = lines.withLock { $0 }.compactMap(WizardTiming.parse)
        #expect(stages.map(\.stage) == ["quick", "failing"])
        #expect(stages[1].seconds >= 0.02)
        // A skipped stage below the threshold stays out of the summary.
        let quiet = Mutex<[String]>([])
        await WizardTiming.measure("skipped", emit: { line in quiet.withLock { $0.append(line) } }, minimumSeconds: 1) { }
        #expect(quiet.withLock { $0 }.isEmpty)
    }

    @Test func collectorGroupsSumsAndSummarizes() {
        let collector = WizardTiming.Collector()
        #expect(collector.record("Extracting clip 1/2", group: "Reel 1 of 2") == false)
        #expect(collector.record("TIMING:extract clips=20.1", group: "Reel 1 of 2"))
        #expect(collector.record("TIMING:compositor=15", group: "Reel 1 of 2"))
        #expect(collector.record("TIMING:social caption=6.1", group: "Reel 1 of 2"))
        // Several ffmpeg passes under one stage name add up.
        #expect(collector.record("TIMING:compositor=5", group: "Reel 1 of 2"))
        #expect(collector.record("TIMING:camera focus=2.5", group: "Preparation"))
        #expect(collector.record("TIMING:extract clips=18", group: "Reel 2 of 2"))
        #expect(collector.groupNames == ["Reel 1 of 2", "Preparation", "Reel 2 of 2"])
        #expect(collector.entries(group: "Reel 1 of 2") == [
            .init(stage: "extract clips", seconds: 20.1), .init(stage: "compositor", seconds: 20),
            .init(stage: "social caption", seconds: 6.1),
        ])
        #expect(collector.summaryLines(total: 70) == [
            "Timings · Reel 1 of 2: extract clips 20.1s · compositor 20.0s · social caption 6.1s",
            "Timings · Preparation: camera focus 2.5s",
            "Timings · Reel 2 of 2: extract clips 18.0s",
            "Timings · total 1m 10s from Generate to results",
        ])
        #expect(WizardTiming.Collector().summaryLines() == [])
    }
}
