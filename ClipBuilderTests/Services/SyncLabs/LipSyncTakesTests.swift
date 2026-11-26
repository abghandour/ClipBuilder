import Foundation
import Testing
@testable import Clip_Builder

struct LipSyncTakesTests {
    private func take(_ start: Double, _ end: Double, path: String = "/v/a.mp4", key: String = "k") -> LipSyncTakes.Take {
        .init(key: key, sourcePath: path, sourceStart: start, sourceEnd: end, model: "lipsync-2",
              created: Date(timeIntervalSince1970: 0), cues: [])
    }

    @Test func theKeyFollowsTheStretchAndItsLinesButNotTheReel() {
        let cue = LipSyncTakes.Cue(audio: "a.mp3", offset: 0.5, stretch: 1)
        let request = LipSyncTakes.Request(sourcePath: "/v/a.mp4", sourceStart: 10, sourceEnd: 20, cues: [cue])
        let key = LipSyncTakes.key(request, sourceFingerprint: "f", model: .standard)
        #expect(key == LipSyncTakes.key(request, sourceFingerprint: "f", model: .standard))
        var moved = request
        moved.sourceEnd = 21
        #expect(LipSyncTakes.key(moved, sourceFingerprint: "f", model: .standard) != key)
        var reworded = request
        reworded.cues[0].audio = "b.mp3"
        #expect(LipSyncTakes.key(reworded, sourceFingerprint: "f", model: .standard) != key)
        #expect(LipSyncTakes.key(request, sourceFingerprint: "g", model: .standard) != key)
        // A paid take's cut file is renamed when its Drive upload lands; the take is the same.
        var named = request, renamed = request
        named.cues[0].identity = "take-1"
        renamed.cues[0].identity = "take-1"
        renamed.cues[0].audio = "after-upload.caf"
        #expect(LipSyncTakes.key(named, sourceFingerprint: "f", model: .standard)
                == LipSyncTakes.key(renamed, sourceFingerprint: "f", model: .standard))
        #expect(LipSyncTakes.key(request, sourceFingerprint: "f", model: .sync3) != key)
    }

    @Test func aReadComesFromATakeOnlyWhenTheTakeCoversAllOfIt() {
        let takes = [LipSyncTakes.Substitute(sourcePath: "/v/a.mp4", sourceStart: 10, sourceEnd: 20, path: "/t/k.mp4", key: "k", takeStart: 10)]
        #expect(LipSyncTakes.substitute(path: "/v/a.mp4", start: 12, span: 3, in: takes)?.key == "k")
        #expect(LipSyncTakes.substitute(path: "/v/a.mp4", start: 10, span: 10, in: takes)?.key == "k")
        #expect(LipSyncTakes.substitute(path: "/v/a.mp4", start: 18, span: 3, in: takes) == nil)
        #expect(LipSyncTakes.substitute(path: "/v/a.mp4", start: 9, span: 3, in: takes) == nil)
        #expect(LipSyncTakes.substitute(path: "/v/b.mp4", start: 12, span: 3, in: takes) == nil)
    }

    @Test func coverageAddsOverlappingTakesOnceAndNamesAWholeTake() {
        let partial = LipSyncTakes.coverage(path: "/v/a.mp4", start: 10, end: 20,
                                            takes: [take(8, 14), take(12, 16, key: "j"), take(0, 30, path: "/v/b.mp4")])
        #expect(abs(partial.synced - 6) < 0.001 && partial.take == nil)
        #expect(partial.label == "Lip-synced 60%" && !partial.isComplete)
        let whole = LipSyncTakes.coverage(path: "/v/a.mp4", start: 10, end: 20, takes: [take(9, 21)])
        #expect(whole.isComplete && whole.take?.key == "k" && whole.label == "Lip-synced")
        let none = LipSyncTakes.coverage(path: "/v/a.mp4", start: 10, end: 20, takes: [])
        #expect(none.label == nil)
        #expect(LipSyncTakes.summary([none]) == nil)
        #expect(LipSyncTakes.summary([partial, whole]) == "Lip sync: 1 of 2 clips ready · 16 s of 20 s")
    }

    @Test func sameFootageTwiceIsOneRequestAndClashingLinesAreNone() {
        func request(_ start: Double, _ end: Double, _ audio: String) -> LipSyncTakes.Request {
            .init(sourcePath: "/v/a.mp4", sourceStart: start, sourceEnd: end, cues: [.init(audio: audio, offset: 0, stretch: 1)])
        }
        #expect(LipSyncTakes.distinct([request(10, 20, "a"), request(30, 40, "b"), request(10, 20, "a")]).count == 2)
        #expect(LipSyncTakes.distinct([request(10, 20, "a"), request(30, 40, "b"), request(15, 25, "c")]) == [request(30, 40, "b")])
        // Whatever the order, nothing that clashes with anything survives.
        #expect(LipSyncTakes.distinct([request(10, 20, "a"), request(30, 40, "b"), request(15, 35, "c"), request(30, 40, "d")]).isEmpty)
    }

    @Test func aLongerTakeWithTheSameLinesCoversARequest() {
        var long = take(10, 30)
        long.fingerprint = "f"
        long.cues = [.init(audio: "a", offset: 1, stretch: 1, seconds: 4), .init(audio: "b", offset: 12, stretch: 1)]
        let second = LipSyncTakes.Request(sourcePath: "/v/a.mp4", sourceStart: 20, sourceEnd: 30,
                                          cues: [.init(audio: "b", offset: 2, stretch: 1)])
        #expect(LipSyncTakes.covering(second, fingerprint: "f", model: .standard, in: [long])?.key == "k")
        #expect(LipSyncTakes.covering(second, fingerprint: "g", model: .standard, in: [long]) == nil)
        // A line that starts before the request and is still heard inside it.
        var spilling = long
        spilling.cues.insert(.init(audio: "s", offset: 8, stretch: 1, seconds: 3), at: 1)
        #expect(LipSyncTakes.covering(second, fingerprint: "f", model: .standard, in: [spilling]) == nil)
        var reworded = second
        reworded.cues[0].audio = "c"
        #expect(LipSyncTakes.covering(reworded, fingerprint: "f", model: .standard, in: [long]) == nil)
    }

    @Test func takesOnDiskNeedBothTheSidecarAndTheVideo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lipsync-takes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try LipSyncTakes.write(take(1, 5, key: "kept"), in: folder)
        try LipSyncTakes.write(take(1, 5, key: "orphan"), in: folder)
        try Data([0]).write(to: LipSyncTakes.video("kept", in: folder))
        #expect(LipSyncTakes.all(in: folder).map(\.key) == ["kept"])
    }

    @Test func theSpeechTrackPlacesEachLineOnSilence() {
        let arguments = LipSyncTakes.speechArguments(cues: [("/d/a.mp3", .init(audio: "a.mp3", offset: 1.25, stretch: 1.1))],
                                                     seconds: 8, output: "/s/out.wav")
        let graph = arguments[(arguments.firstIndex(of: "-filter_complex") ?? 0) + 1]
        #expect(graph.contains("adelay=1250:all=1") && graph.contains("atempo=") && graph.contains("amix=inputs=2:duration=first"))
        #expect(arguments.last == "/s/out.wav")
    }
}
