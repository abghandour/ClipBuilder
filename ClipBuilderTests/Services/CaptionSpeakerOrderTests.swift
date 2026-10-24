import Testing
@testable import Clip_Builder

struct CaptionSpeakerOrderTests {
    @Test func firstSpeechHonorsRowAttributionAndThenAppendsSilentRoster() {
        let turns: [SpeakerTurn] = [
            .init(videoID: 1, start: 4, end: 8, cluster: 1, confidence: 1, personKey: "ana"),
            .init(videoID: 1, start: 0, end: 4, cluster: 0, confidence: 1, personKey: "ana"),
            .init(videoID: 1, start: 8, end: 10, cluster: 2, confidence: 1, personKey: "unknown")]
        let rows: [TranscriptRow] = [
            .init(id: 2, videoID: 1, language: "en", isTranslation: false,
                  startTime: 8, endTime: 10, text: "Unknown", speakerKey: ""),
            .init(id: 1, videoID: 1, language: "en", isTranslation: false,
                  startTime: 0, endTime: 4, text: "Bob first", speakerKey: "bob"),
            .init(id: 3, videoID: 1, language: "fr", isTranslation: true,
                  startTime: 0, endTime: 4, text: "Translation", speakerKey: "translated")]
        #expect(CaptionSpeakerOrder.ordinals(turns: turns, rows: rows, roster: ["zoe", "bob", "chris"]) ==
                ["bob": 1, "ana": 2, "chris": 3, "zoe": 4])
    }

    @Test func manualSpeechInsideAnAutomaticTurnGetsItsOwnSlot() {
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 10, cluster: 0, confidence: 1, personKey: "ana")]
        let rows = [TranscriptRow(id: 1, videoID: 1, language: "en", isTranslation: false,
            startTime: 4, endTime: 6, text: "An interruption", speakerKey: "bob")]
        #expect(CaptionSpeakerOrder.ordinals(turns: turns, rows: rows, roster: []) == ["ana": 1, "bob": 2])
    }

    @Test func concatenatedVideosKeepSourceOrderDespiteRestartedClocks() {
        let turns: [SpeakerTurn] = [
            .init(videoID: 9, start: 20, end: 30, cluster: 0, confidence: 1, personKey: "first"),
            .init(videoID: 9, start: 30, end: 40, cluster: 1, confidence: 1, personKey: "shared"),
            .init(videoID: 2, start: 0, end: 10, cluster: 0, confidence: 1, personKey: "second"),
            .init(videoID: 2, start: 10, end: 20, cluster: 1, confidence: 1, personKey: "shared")]
        let rows = [TranscriptRow(id: 1, videoID: 2, language: "en", isTranslation: false,
            startTime: 0, endTime: 10, text: "Corrected", speakerKey: "corrected")]
        #expect(CaptionSpeakerOrder.ordinals(turns: turns, rows: rows, roster: []) ==
                ["first": 1, "shared": 2, "corrected": 3])
        let manualFirst = TranscriptRow(id: 2, videoID: 9, language: "en", isTranslation: false,
            startTime: 20, endTime: 30, text: "Manual first source", speakerKey: "first")
        #expect(CaptionSpeakerOrder.ordinals(turns: turns.filter { $0.videoID == 2 },
            rows: [manualFirst] + rows, roster: []) == ["first": 1, "corrected": 2, "shared": 3])
    }

    @Test func positionsValidateAndFallBackToRunChoice() {
        let ordinals = ["ana": 1, "bob": 2]
        for valid in ["bottom", "middle", "top", "custom:0.2500,0.7500"] {
            #expect(CaptionSpeakerOrder.position(forPerson: "ana", ordinals: ordinals,
                positions: ["speaker1": valid], runPosition: "auto") == valid)
        }
        for invalid in ["", "auto", "left", "Top", "custom:no,0.5", "custom:nan,0.5"] {
            #expect(CaptionSpeakerOrder.position(forPerson: "ana", ordinals: ordinals,
                positions: ["speaker1": invalid], runPosition: "middle") == "middle")
        }
        for person in [nil, "bob", "missing"] {
            #expect(CaptionSpeakerOrder.position(forPerson: person, ordinals: ordinals,
                positions: ["speaker1": "top"], runPosition: "bottom") == "bottom")
        }
        #expect(CaptionSpeakerOrder.position(forPerson: "ana", ordinals: ordinals,
            positions: nil, runPosition: "custom:0.5,0.6") == "custom:0.5,0.6")
    }

    @Test func slotsRoundTripAndRejectMalformedKeys() {
        for ordinal in [1, 2, 10, 100] {
            #expect(CaptionSpeakerOrder.ordinal(slot: CaptionSpeakerOrder.slot(ordinal)) == ordinal)
        }
        for invalid in ["speaker", "speaker0", "speaker-1", "speaker01", "person:ana", "speaker1x"] {
            #expect(CaptionSpeakerOrder.ordinal(slot: invalid) == nil)
        }
    }

    @Test func sourceOrderIncludesSelectedVideosBeforeTheirClipsAreUsed() {
        var first = Fixtures.scene(id: 1)
        first.videoID = 3
        first.videoPath = "/tmp/first.mp4"
        first.runID = 11
        first.favorite = true
        var second = Fixtures.scene(id: 2)
        second.videoID = 7
        second.videoPath = "/tmp/second.mp4"
        second.runID = 12
        var ignored = Fixtures.scene(id: 3)
        ignored.videoID = 1
        ignored.ignored = true
        let scenes = [second, ignored, first]
        var options = WizardOptions()
        #expect(CaptionSpeakerOrder.sourceVideoIDs(scenes: scenes, options: options) == [3, 7])
        options.favoritesOnly = true
        #expect(CaptionSpeakerOrder.sourceVideoIDs(scenes: scenes, options: options) == [3])
        options.favoritesOnly = false
        options.selectedRunIDs = [12]
        #expect(CaptionSpeakerOrder.sourceVideoIDs(scenes: scenes, options: options) == [7])
        options.selectedRunIDs = []
        options.sourcesRestricted = true
        options.sourceVideoPaths = [first.videoPath]
        #expect(CaptionSpeakerOrder.sourceVideoIDs(scenes: scenes, options: options) == [3])
    }
}
