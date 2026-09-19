import Foundation
import Testing
@testable import Clip_Builder

@Suite("Voice profiles")
struct VoiceProfilesTests {
    private let tiles = [
        PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "marcello"),
        PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1),
    ]

    private func enrollment(trust: Bool, kind: SpeakerTracker.FeatureKind = .embedding,
                            file: [Int: [Double]] = [0: [1, 0, 0], 1: [0, 1, 0]]) -> SpeakerTracker.Enrollment {
        var enrollment = SpeakerTracker.Enrollment(centroids: file, windowsPerSlot: [0: 12, 1: 9], separation: 5,
                                                   featureKind: kind, correctionWindowsPerSlot: [0: 3],
                                                   fileCentroids: file)
        enrollment.heldOutAgreement = trust ? 0.99 : 0.5
        return enrollment
    }

    @Test("lines attributed by hand count as unlearned until the map's turn names the same person")
    func unlearnedCorrections() {
        func row(_ id: Int64, _ start: Double, _ end: Double, key: String?, translation: Bool = false) -> TranscriptRow {
            TranscriptRow(id: id, videoID: 1, language: "pt", isTranslation: translation, startTime: start, endTime: end,
                          text: "…", originalText: nil, wordsJSON: nil, provider: "apple", model: "m", speakerKey: key)
        }
        var agreeing = SpeakerTurn(videoID: 1, start: 0, end: 10, cluster: 0, confidence: 1); agreeing.personKey = "marcello"
        var other = SpeakerTurn(videoID: 1, start: 10, end: 20, cluster: 1, confidence: 1); other.personKey = "thiago"
        var bare = SpeakerTurn(videoID: 1, start: 20, end: 30, cluster: 2, confidence: 1); bare.tile = 2
        let rows = [row(1, 0, 5, key: "marcello"), row(2, 12, 15, key: "marcello"), row(3, 22, 25, key: "marcello"),
                    row(4, 32, 35, key: "marcello"), row(5, 12, 15, key: ""), row(6, 12, 15, key: nil),
                    row(7, 12, 15, key: "marcello", translation: true)]
        #expect(TranscriptSpeakers.unlearnedCorrections(rows: rows, turns: [agreeing, other, bare]) == 3)
        #expect(TranscriptSpeakers.unlearnedCorrections(rows: rows, turns: []) == 4)
    }

    @Test("profiles combine per person by window count into a unit vector; other dimensions are left out")
    func combine() {
        let voices = VoiceProfiles.combined([
            VoiceProfile(personKey: "a", videoID: 1, vector: [1, 0], windows: 30),
            VoiceProfile(personKey: "a", videoID: 2, vector: [0, 1], windows: 10),
            VoiceProfile(personKey: "a", videoID: 3, vector: [0, 0, 1], windows: 100),
            VoiceProfile(personKey: "b", videoID: 1, vector: [0, -1], windows: 5),
        ])
        let a = try! #require(voices["a"])
        #expect(a.windows == 40)
        #expect(abs(a.vector[0] - 3 / sqrt(10)) < 1e-9 && abs(a.vector[1] - 1 / sqrt(10)) < 1e-9)
        #expect(voices["b"]?.vector == [0, -1])
        let priors = VoiceProfiles.priors(tiles: [PodcastTile(index: 2, x: 0, y: 0, w: 1, h: 1, personKey: "b"),
                                                  PodcastTile(index: 3, x: 0, y: 0, w: 1, h: 1, personKey: "nobody")],
                                          voices: voices)
        #expect(priors == [SpeakerTracker.Prior(slot: 2, vector: [0, -1], windows: 5)])
    }

    @Test("a trusted neural map remembers the file's own centroid per named tile; untrusted or spectral maps remember nothing")
    func learned() {
        let profiles = VoiceProfiles.learned(videoID: 7, tiles: tiles, enrollment: enrollment(trust: true))
        #expect(profiles == [VoiceProfile(personKey: "marcello", videoID: 7, vector: [1, 0, 0], windows: 12, correctionWindows: 3)])
        #expect(VoiceProfiles.learned(videoID: 7, tiles: tiles, enrollment: enrollment(trust: false)).isEmpty)
        #expect(VoiceProfiles.learned(videoID: 7, tiles: tiles, enrollment: enrollment(trust: true, kind: .spectral)).isEmpty)
        #expect(VoiceProfiles.learned(videoID: 7, tiles: tiles, enrollment: nil).isEmpty)
    }

    @Test("an unnamed tile takes the remembered voice nearest to what the file taught, unless someone already seated or too close a runner-up")
    func naming() {
        let voices: [String: VoiceProfiles.Voice] = [
            "marcello": .init(vector: [1, 0, 0], windows: 20),
            "thiago": .init(vector: [0, 0.96, 0.28], windows: 20),
        ]
        let named = VoiceProfiles.named(tiles: tiles, enrollment: enrollment(trust: true), voices: voices)
        #expect(named.tiles.map(\.personKey) == ["marcello", "thiago"])
        #expect(named.namings.count == 1 && named.namings[0].tile == 1 && named.namings[0].cosine > 0.9)
        // The seated person is not a candidate even when the tile sounds like them.
        let alike = VoiceProfiles.named(tiles: tiles, enrollment: enrollment(trust: true, file: [1: [1, 0, 0]]),
                                        voices: voices)
        #expect(alike.tiles.map(\.personKey) == ["marcello", nil])
        // Two remembered voices equally close: nobody is named.
        let ambiguous = VoiceProfiles.named(tiles: tiles, enrollment: enrollment(trust: true, file: [1: [0, 1, 1]]),
                                            voices: ["x": .init(vector: [0, 1, 0], windows: 1),
                                                     "y": .init(vector: [0, 0, 1], windows: 1)])
        #expect(ambiguous.namings.isEmpty)
        // A voice nobody remembers stays unnamed.
        let stranger = VoiceProfiles.named(tiles: tiles, enrollment: enrollment(trust: true, file: [1: [0, 0, -1]]),
                                           voices: voices)
        #expect(stranger.namings.isEmpty)
        #expect(VoiceProfiles.named(tiles: tiles, enrollment: enrollment(trust: true, kind: .spectral), voices: voices).namings.isEmpty)
    }
}
