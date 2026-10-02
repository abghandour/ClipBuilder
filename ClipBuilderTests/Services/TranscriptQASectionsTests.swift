import Testing
@testable import Clip_Builder

@Suite("Transcript Q&A sections")
struct TranscriptQASectionsTests {
    private func row(_ id: Int64, _ start: Double, _ end: Double, _ text: String = "Line") -> TranscriptRow {
        TranscriptRow(id: id, videoID: 1, language: "en", isTranslation: false,
                      startTime: start, endTime: end, text: text, originalText: nil,
                      wordsJSON: nil, provider: nil, model: nil)
    }

    private func scene(_ id: Int64, _ start: Double, _ end: Double) -> SceneRecord {
        var scene = Fixtures.scene(id: id, start: start, end: end)
        scene.tags = ["podcast", "q&a", "podcast-exchange"]
        scene.videoDuration = 100
        return scene
    }

    @Test func ordersSectionsAndFindsQuestionAndSpeakers() {
        let rows = [row(4, 32, 34, "Later answer"), row(3, 30, 32, "Later question?"),
                    row(2, 12, 16, "First answer"), row(1, 10, 12, "First question?")]
        let result = TranscriptQASections.sections(scenes: [scene(2, 30, 40), scene(1, 10, 20), Fixtures.scene(id: 3)],
                                                  rows: rows, labels: [1: "Host", 2: "Guest", 3: "Guest", 4: "Host"])
        #expect(result.map(\.id) == [1, 2])
        #expect(result.map(\.question) == ["First question?", "Later question?"])
        #expect(result[0].asker == "Host")
        #expect(result[0].answerer == "Guest")
        #expect(result[1].asker == "Guest")
        #expect(result[1].answerer == "Host")
    }

    @Test func ignoresHiddenSectionsAndLinesFromAnotherVideo() {
        var ignored = scene(2, 0, 10)
        ignored.ignored = true
        var other = row(1, 0, 2, "Other file")
        other.videoID = 2
        let result = TranscriptQASections.sections(scenes: [ignored, scene(1, 0, 10)], rows: [other], labels: [:])
        #expect(result.count == 1)
        #expect(result[0].question == "No transcript lines in this section")
    }

    @Test func sectionWithNoLinesStillHasRangeAndNoSpeakers() {
        let result = TranscriptQASections.sections(scenes: [scene(1, 10, 20)], rows: [], labels: [:])
        #expect(result.count == 1)
        #expect(result[0].range == 10...20)
        #expect(result[0].question == "No transcript lines in this section")
        #expect(result[0].asker == nil)
        #expect(result[0].answerer == nil)
        #expect(TranscriptQASections.lines(rows: [], range: 10...20).isEmpty)
    }

    @Test func answererIsTheFirstDifferentSpeaker() {
        let rows = [row(1, 0, 2), row(2, 2, 4), row(3, 4, 6), row(4, 6, 8)]
        let result = TranscriptQASections.sections(scenes: [scene(1, 0, 10)], rows: rows,
                                                  labels: [1: "Host", 2: "Host", 4: "Guest"])
        #expect(result[0].answerer == "Guest")
        let single = TranscriptQASections.sections(scenes: [scene(1, 0, 10)], rows: rows, labels: [1: "Host", 2: "Host"])
        #expect(single[0].answerer == nil)
    }

    @Test func originalLanguageWinsTiedStartTimes() {
        var translation = row(1, 0, 2, "Translated question")
        translation.isTranslation = true
        let result = TranscriptQASections.sections(scenes: [scene(1, 0, 10)],
                                                  rows: [translation, row(2, 0, 2, "Original question")], labels: [:])
        #expect(result[0].question == "Original question")
    }

    @Test func contextAtFileStartMiddleAndEnd() {
        let rows: [TranscriptRow] = (0..<12).map { (index: Int) -> TranscriptRow in
            let start = Double(index) * 2
            return row(Int64(index), start, start + 2)
        }
        let start = TranscriptQASections.lines(rows: rows, range: 0...4)
        #expect(start.map(\.id) == [0, 1, 2, 3, 4, 5])
        #expect(start.filter(\.isInside).map(\.id) == [0, 1])
        let middle = TranscriptQASections.lines(rows: rows, range: 10...14)
        #expect(middle.map(\.id) == Array(Int64(1)...10))
        #expect(middle.filter(\.isInside).map(\.id) == [5, 6])
        let end = TranscriptQASections.lines(rows: rows, range: 20...24)
        #expect(end.map(\.id) == [6, 7, 8, 9, 10, 11])
        #expect(end.filter(\.isInside).map(\.id) == [10, 11])
    }

    @Test func emptySectionShowsNearbyContext() {
        let rows = [row(1, 0, 2), row(2, 2, 4), row(3, 10, 12), row(4, 12, 14)]
        let lines = TranscriptQASections.lines(rows: rows, range: 5...9)
        #expect(lines.map(\.id) == [1, 2, 3, 4])
        #expect(lines.allSatisfy { !$0.isInside })
        #expect(TranscriptQASections.lines(rows: rows, range: 20...22).map(\.id) == [1, 2, 3, 4])
    }

    @Test func membershipMatchesSceneTagMidpoints() {
        #expect(TranscriptQASections.contains(row(1, 9, 11), in: 10...20))
        #expect(!TranscriptQASections.contains(row(2, 19, 21), in: 10...20))
    }

    @Test func snapsOnlyToTheRequestedEndWithinTolerance() {
        let rows = [row(1, 10, 14), row(2, 20, 24)]
        #expect(TranscriptQASections.snap(11.5, edge: .start, rows: rows) == 10)
        #expect(TranscriptQASections.snap(11.51, edge: .start, rows: rows) == 11.51)
        #expect(TranscriptQASections.snap(22.5, edge: .end, rows: rows) == 24)
        #expect(TranscriptQASections.snap(22.49, edge: .end, rows: rows) == 22.49)
        #expect(TranscriptQASections.snap(13.8, edge: .start, rows: rows) == 13.8)
        #expect(TranscriptQASections.snap(10, edge: .start, rows: []) == 10)
        #expect(TranscriptQASections.snap(11, edge: .start, rows: rows, tolerance: 0.5) == 11)
        #expect(TranscriptQASections.snap(15, edge: .start, rows: rows, tolerance: 5) == 10)
    }

    @Test func startHereCannotInvertOrShrinkBelowOneSecond() {
        #expect(TranscriptQASections.setting(.start, at: 15, in: 10...20, videoDuration: 100) == 15...20)
        #expect(TranscriptQASections.setting(.start, at: 5, in: 10...20, videoDuration: 100) == 5...20)
        #expect(TranscriptQASections.setting(.start, at: 19.5, in: 10...20, videoDuration: 100) == 19...20)
        #expect(TranscriptQASections.setting(.start, at: 25, in: 10...20, videoDuration: 100) == 19...20)
    }

    @Test func releasingSnapsOnlyMovedEndsThenEnforcesTheLimits() {
        let rows = [row(1, 10, 14), row(2, 20, 24), row(3, 30, 34)]
        #expect(TranscriptQASections.releasing(start: 11, end: 23.5, from: 5...23.5,
                                              rows: rows, videoDuration: 100) == 10...23.5)
        #expect(TranscriptQASections.releasing(start: 10.5, end: 25, from: 10.5...30,
                                              rows: rows, videoDuration: 100) == 10.5...24)
        #expect(TranscriptQASections.releasing(start: 11, end: 25, from: 5...30,
                                              rows: rows, videoDuration: 100) == 10...24)
        #expect(TranscriptQASections.releasing(start: 29.5, end: 30, from: 20...30,
                                              rows: rows, videoDuration: 100) == 29...30)
        #expect(TranscriptQASections.releasing(start: 10, end: 14.5, from: 10...20,
                                              rows: rows, videoDuration: 13) == 10...13)
    }

    @Test func endHereCannotInvertOrShrinkBelowOneSecond() {
        #expect(TranscriptQASections.setting(.end, at: 15, in: 10...20, videoDuration: 100) == 10...15)
        #expect(TranscriptQASections.setting(.end, at: 25, in: 10...20, videoDuration: 100) == 10...25)
        #expect(TranscriptQASections.setting(.end, at: 10.5, in: 10...20, videoDuration: 100) == 10...11)
        #expect(TranscriptQASections.setting(.end, at: 5, in: 10...20, videoDuration: 100) == 10...11)
    }

    @Test func videoClampAndVeryShortFiles() {
        #expect(TranscriptQASections.clamp(start: -5, end: 105, videoDuration: 100) == 0...100)
        #expect(TranscriptQASections.clamp(start: 110, end: 120, videoDuration: 100) == 99...100)
        #expect(TranscriptQASections.clamp(start: 40, end: 30, videoDuration: 100) == 40...41)
        #expect(TranscriptQASections.setting(.start, at: -5, in: 10...20, videoDuration: 100) == 0...20)
        #expect(TranscriptQASections.setting(.end, at: 105, in: 10...20, videoDuration: 100) == 10...100)
        #expect(TranscriptQASections.clamp(start: 0.3, end: 2, videoDuration: 0.4) == 0...0.4)
        #expect(TranscriptQASections.clamp(start: 1, end: 2, videoDuration: 0) == 0...0)
    }

    @Test func trimmedFlagIncludesExtensionsAndClearsAtOriginal() {
        var changed = scene(1, 10, 20)
        #expect(!TranscriptQASections.sections(scenes: [changed], rows: [], labels: [:])[0].isTrimmed)
        changed.startTime = 9
        #expect(TranscriptQASections.sections(scenes: [changed], rows: [], labels: [:])[0].isTrimmed)
        changed.startTime = 10
        changed.endTime = 19
        #expect(TranscriptQASections.sections(scenes: [changed], rows: [], labels: [:])[0].isTrimmed)
        changed.endTime = 20
        #expect(!TranscriptQASections.sections(scenes: [changed], rows: [], labels: [:])[0].isTrimmed)
    }

    @Test func filmstripHasRoomToExtendAndStaysInVideo() {
        let middle = TranscriptQASections.window(for: 40...60, videoDuration: 100)
        #expect(middle.start == 20)
        #expect(middle.end == 80)
        #expect(!middle.needsRecentering(24...76))
        #expect(middle.needsRecentering(23...60))
        #expect(middle.needsRecentering(40...77))
        let start = TranscriptQASections.window(for: 0...10, videoDuration: 100)
        #expect(start.start == 0)
        #expect(start.end == 50)
        let end = TranscriptQASections.window(for: 90...100, videoDuration: 100)
        #expect(end.start == 50)
        #expect(end.end == 100)
        let long = TranscriptQASections.window(for: 50...300, videoDuration: 400)
        #expect(long.start == 30)
        #expect(long.end == 320)
    }
}
