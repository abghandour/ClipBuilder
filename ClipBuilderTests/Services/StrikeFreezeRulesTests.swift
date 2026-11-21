import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Strike freeze rules")
struct StrikeFreezeRulesTests {
    @Test("Contact reads filter generation, rules and range without decoding tracks, across videos")
    func contactQuery() async throws {
        let temp = try await TempDatabase()
        let first = try await temp.seedVideo()
        let second = try await temp.seedVideo()
        let generation = try await temp.database.advanceFightEventGeneration(videoID: first)
        let raw = try SQLiteConnection(path: temp.path.path)
        func insert(_ videoID: Int64, time: Double, generation: Int64, version: Int) throws {
            try raw.execute("""
                INSERT INTO strike_highlights(video_id, at_time, fighter_key, contact_time, track_json, rules_version, generation)
                VALUES (?, ?, 'a', ?, 'deliberately not track JSON', ?, ?)
                """, [.integer(videoID), .real(time), .real(time), .integer(Int64(version)), .integer(generation)])
        }
        let version = StrikeHighlightRules.version
        try insert(first, time: 1, generation: generation, version: version)
        try insert(first, time: 2, generation: generation - 1, version: version)
        try insert(first, time: 3, generation: generation, version: version - 1)
        try insert(first, time: 4, generation: generation, version: version)
        try insert(second, time: 5, generation: 0, version: version)
        let contacts = try await temp.database.fetchStrikeContacts(videoIDs: [first, second])
        #expect(contacts[first] == [1, 4] && contacts[second] == [5])
        #expect(try await temp.database.fetchStrikeContacts(videoIDs: [first], overlapping: 3...6)[first] == [4])
        #expect(try await temp.database.fetchStrikeContacts(videoIDs: []).isEmpty)
        try await temp.database.advanceFightEventGeneration(videoID: first)
        #expect(try await temp.database.fetchStrikeContacts(videoIDs: [first]).isEmpty)
    }

    @Test("Contact loading ignores unrelated clip edits but invalidates changed source ranges")
    func contactSourceIdentity() {
        let clip = Fixtures.timelineClip()
        var edited = clip
        edited.volume = 2
        edited.startTime += 3
        #expect(StrikeFreezeRules.sameContactSource(edited, clip))
        edited.sourceStart = 5
        #expect(!StrikeFreezeRules.sameContactSource(edited, clip))
        #expect(!StrikeFreezeRules.sameContactSource(nil, clip))
    }

    @Test("contacts must clear both edges and the previous kept contact")
    func distancesAndMerging() {
        let clip = Fixtures.timelineClip(sourceStart: 2, duration: 2)
        #expect(StrikeFreezeRules.contacts(clip, contacts: [4, 3.751, 3.75, 2.49, 2.5, 2.25, 2.249, 2])
            == [2.25, 2.5, 3.75])
        #expect(StrikeFreezeRules.contacts(clip, contacts: [2.7, 2.6, 2.5, 2.5, .nan, .infinity]) == [2.5])
    }

    @Test("the earliest eight qualifying contacts win")
    func cap() {
        let clip = Fixtures.timelineClip(sourceStart: 0, duration: 20)
        #expect(StrikeFreezeRules.contacts(clip, contacts: Array((1...19).reversed()).map(Double.init))
            == (1...8).map(Double.init))
    }

    @Test("minimum pieces are measured in screen seconds", arguments: [0.5, 2.0])
    func speed(_ speed: Double) throws {
        let clip = Fixtures.timelineClip(sourceStart: 10, duration: 2, startTime: 3, speed: speed)
        let start = 10.0
        let end = start + clip.sourceSpan
        let minimum = StrikeFreezeRules.minimumPiece * speed
        let contacts = [start + minimum, start + minimum * 2, end - minimum]
        #expect(StrikeFreezeRules.contacts(clip, contacts: contacts + [start + minimum - 0.001, end - minimum + 0.001])
            == contacts)
        let pieces = StrikeFreezeRules.pieces(clip, contacts: contacts, hold: 0.8)
        #expect(pieces.count == 7)
        let moving = pieces.filter { $0.hold != true }
        #expect(abs(try #require(moving.first).duration - 0.25) < 1e-9)
        #expect(moving.allSatisfy { $0.speed == speed })
        #expect(abs(moving.reduce(0) { $0 + $1.duration } - clip.duration) < 1e-9)
        #expect(abs(pieces.reduce(0) { $0 + $1.duration } - (clip.duration + 2.4)) < 1e-9)
    }

    @Test("pieces alternate, retain settings and origin, and keep transitions at the ends")
    func pieces() throws {
        var clip = Fixtures.timelineClip(sourceStart: 2, duration: 4, startTime: 5)
        clip.transIn = "fade"
        clip.transOut = "fadeblack"
        clip.strikeHighlights = true
        clip.wide = true
        clip.centerStage = true
        clip.cameraPath = [CameraPathKeyframe(t: 0, x: 0, y: 0, w: 0.4, h: 1),
                           CameraPathKeyframe(t: 4, x: 0.6, y: 0, w: 0.4, h: 1)]
        let pieces = StrikeFreezeRules.pieces(clip, contacts: [3, 5], hold: 0.8)
        #expect(pieces.count == 5)
        #expect(pieces.map { $0.hold == true } == [false, true, false, true, false])
        #expect(pieces.map(\.sourceStart) == [2, 3, 3, 5, 5])
        #expect(pieces.map(\.sourceEnd) == [3, 3, 5, 5, 6])
        #expect(pieces.map(\.duration) == [1, 0.8, 2, 0.8, 1])
        for (piece, expected) in zip(pieces, [5.0, 6, 6.8, 8.8, 9.6]) {
            #expect(abs(piece.startTime - expected) < 1e-9)
        }
        #expect(Set(pieces.map(\.uid)).count == pieces.count)
        #expect(pieces.allSatisfy { $0.uid != clip.uid && $0.originKey == clip.originKey })
        #expect(pieces.allSatisfy { $0.strikeHighlights == true && $0.centerStage && $0.wide })
        #expect(pieces.first?.transIn == clip.transIn && pieces.last?.transOut == clip.transOut)
        #expect(pieces.dropFirst().allSatisfy { $0.transIn == nil })
        #expect(pieces.dropLast().allSatisfy { $0.transOut == nil })
        #expect(pieces.filter { $0.hold == true }.allSatisfy { $0.speed == nil && $0.sourceSpan == 0 })

        let firstSplit = try #require(TimelineSplit.pieces(clip, at: 6))
        let secondSplit = try #require(TimelineSplit.pieces(firstSplit.tail, at: 8))
        #expect(pieces[0].cameraPath == firstSplit.head.cameraPath)
        #expect(pieces[2].cameraPath == secondSplit.head.cameraPath)
        #expect(pieces[4].cameraPath == secondSplit.tail.cameraPath)
        let heldPath = try #require(pieces[1].cameraPath)
        #expect(abs(try #require(heldPath.first).x - 0.15) < 1e-9)
        #expect(heldPath.first?.x == heldPath.last?.x)
    }

    @Test("every produced piece is idempotent, including the capped tail after reload")
    func idempotence() throws {
        let clip = Fixtures.timelineClip(sourceStart: 0, duration: 20)
        let contacts = (1...19).map(Double.init) + [1.1, 2.1]
        let pieces = StrikeFreezeRules.pieces(clip, contacts: contacts, hold: 0.8)
        #expect(pieces.count == 17)
        for piece in pieces {
            #expect(StrikeFreezeRules.contacts(piece, contacts: contacts).isEmpty)
            #expect(StrikeFreezeRules.pieces(piece, contacts: contacts, hold: 0.8).isEmpty)
            let reloaded = try JSONDecoder().decode(TimelineClip.self, from: JSONEncoder().encode(piece))
            #expect(reloaded.strikeImpactsFrozen == true)
            #expect(StrikeFreezeRules.contacts(reloaded, contacts: contacts).isEmpty)
        }
        let originalJSON = try JSONEncoder().encode(clip)
        #expect(!String(decoding: originalJSON, as: UTF8.self).contains("strike_impacts_frozen"))
        #expect(try JSONDecoder().decode(TimelineClip.self, from: originalJSON).strikeImpactsFrozen == nil)
    }

    @Test("unsupported clips, invalid holds and unsplittable source bounds leave no pieces")
    func invalidInput() {
        let clip = Fixtures.timelineClip()
        for hold in [0, -1, 5.1, Double.nan, .infinity] {
            #expect(StrikeFreezeRules.pieces(clip, contacts: [3], hold: hold).isEmpty)
        }
        var invalid = clip
        invalid.sourceEnd = 2.5
        #expect(StrikeFreezeRules.pieces(invalid, contacts: [3], hold: 0.8).isEmpty)
        var bumper = clip; bumper.bumper = true
        var cutaway = clip; cutaway.role = .cutaway
        var hold = clip; hold.hold = true
        for item in [bumper, cutaway, hold] {
            #expect(StrikeFreezeRules.contacts(item, contacts: [3]).isEmpty)
        }
    }
}
