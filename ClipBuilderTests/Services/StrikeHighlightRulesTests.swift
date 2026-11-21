import CoreGraphics
import Foundation
import Testing

@testable import Clip_Builder

@Suite("Strike highlight rules")
struct StrikeHighlightRulesTests {
    typealias Joint = StrikeHighlightRules.Joint

    /// A standing figure 0.6 tall centred on `x`, facing the camera.
    private func figure(x: CGFloat, moving: [Joint: CGPoint] = [:]) -> StrikeHighlightRules.Pose {
        var joints: [Joint: CGPoint] = [
            .nose: CGPoint(x: x, y: 0.2), .neck: CGPoint(x: x, y: 0.27),
            .leftShoulder: CGPoint(x: x + 0.03, y: 0.3), .rightShoulder: CGPoint(x: x - 0.03, y: 0.3),
            .leftElbow: CGPoint(x: x + 0.04, y: 0.4), .rightElbow: CGPoint(x: x - 0.04, y: 0.4),
            .leftWrist: CGPoint(x: x + 0.04, y: 0.34), .rightWrist: CGPoint(x: x - 0.04, y: 0.34),
            .leftHip: CGPoint(x: x + 0.02, y: 0.5), .rightHip: CGPoint(x: x - 0.02, y: 0.5),
            .leftKnee: CGPoint(x: x + 0.02, y: 0.65), .rightKnee: CGPoint(x: x - 0.02, y: 0.65),
            .leftAnkle: CGPoint(x: x + 0.02, y: 0.8), .rightAnkle: CGPoint(x: x - 0.02, y: 0.8),
        ]
        for (joint, point) in moving { joints[joint] = point }
        return .init(joints: joints)
    }

    private let aspect: CGFloat = 16.0 / 9

    @Test("The stored detail round-trips and reads the model's loose words")
    func detail() throws {
        let kick = StrikeDetail(technique: .kick, limb: .left, target: .legs, frameSide: .right)
        #expect(kick.encoded == "kick|left|legs|right")
        #expect(StrikeDetail(kick.encoded) == kick)
        #expect(kick.label == "left kick to the legs")
        #expect(StrikeDetail("punch|||")?.label == "punch")
        #expect(StrikeDetail("armbar") == nil && StrikeDetail(nil) == nil)
        let loose = try #require(StrikeDetail(response: ["technique": "Jab", "limb": "Left", "target": "chin", "side": "R"]))
        #expect(loose == StrikeDetail(technique: .punch, limb: .left, target: .head, frameSide: .right))
        #expect(StrikeDetail(response: ["technique": "leg kick", "target": "thigh"])?.target == .legs)
        #expect(StrikeDetail(response: ["technique": "knee to the body"])?.technique == .knee)
        #expect(StrikeDetail(response: ["technique": NSNull()]) == nil)
    }

    @Test("A punch highlights the arm whose hand reaches the other fighter's head")
    func punch() throws {
        let attacker = figure(x: 0.35, moving: [.leftElbow: CGPoint(x: 0.44, y: 0.26), .leftWrist: CGPoint(x: 0.52, y: 0.21)])
        let defender = figure(x: 0.55)
        let found = try #require(StrikeHighlightRules.highlight(poses: [defender, attacker], technique: .punch,
                                                                target: .head, aspect: aspect))
        #expect(found.limbSide == .left && found.usesArm && found.attackerOnLeft)
        #expect(found.limb.count == 3 && found.limb.last == CGPoint(x: 0.52, y: 0.21))
        // On the head, pulled toward the fist that meets it.
        #expect(found.target.x < 0.55 && found.target.x > 0.5 && abs(found.target.y - 0.2) < 0.03)
        // The model naming the other arm does not move it: geometry wins.
        let named = try #require(StrikeHighlightRules.highlight(poses: [defender, attacker], technique: .punch, limb: .right,
                                                                target: .head, aspect: aspect))
        #expect(named.limbSide == .left)
    }

    @Test("A kick highlights the leg; nobody in reach gives nothing")
    func kick() throws {
        let attacker = figure(x: 0.6, moving: [.rightKnee: CGPoint(x: 0.5, y: 0.6), .rightAnkle: CGPoint(x: 0.43, y: 0.6)])
        let defender = figure(x: 0.4)
        let found = try #require(StrikeHighlightRules.highlight(poses: [attacker, defender], technique: .kick,
                                                                target: .legs, aspect: aspect))
        #expect(found.limbSide == .right && !found.usesArm && !found.attackerOnLeft)
        // The scorer calling a kick to the thigh "body" does not lose it: the
        // named target is a preference, and the circle stays on the leg.
        let misnamed = try #require(StrikeHighlightRules.highlight(poses: [attacker, defender], technique: .kick,
                                                                   target: .body, aspect: aspect))
        #expect(misnamed.limbSide == .right && misnamed.target.y > 0.5)
        #expect(misnamed.cost > found.cost)
        // No technique logged: the reaching leg still wins over any arm.
        #expect(StrikeHighlightRules.highlight(poses: [attacker, defender], technique: nil, aspect: aspect)?.usesArm == false)
        #expect(StrikeHighlightRules.highlight(poses: [figure(x: 0.1), figure(x: 0.9)], technique: .punch, aspect: aspect) == nil)
        #expect(StrikeHighlightRules.highlight(poses: [attacker], technique: .kick, aspect: aspect) == nil)
        // A small figure in the crowd is not a fighter.
        var spectator = figure(x: 0.42)
        spectator.joints = spectator.joints.mapValues { CGPoint(x: $0.x, y: 0.5 + ($0.y - 0.5) * 0.3) }
        #expect(StrikeHighlightRules.highlight(poses: [attacker, spectator], technique: .kick, aspect: aspect) == nil)
    }

    @Test("A track follows the same limb around contact and blends between frames")
    func track() throws {
        let defender = figure(x: 0.55)
        func attacker(reach: CGFloat) -> StrikeHighlightRules.Pose {
            figure(x: 0.35, moving: [.leftElbow: CGPoint(x: 0.4 + reach / 2, y: 0.28), .leftWrist: CGPoint(x: 0.4 + reach, y: 0.22)])
        }
        let step = StrikeHighlightRules.step
        let reaches: [CGFloat] = [0, 0.04, 0.08, 0.13, 0.08, 0.04, 0]
        let frames = reaches.enumerated().map { (time: 10 + Double($0.offset) * step, poses: [attacker(reach: $0.element), defender]) }
        let detail = StrikeDetail(technique: .punch, target: .head)
        let track = try #require(StrikeHighlightRules.track(frames: frames, time: 10.25, detail: detail, aspect: aspect))
        #expect(track.keyframes.count == 7)
        #expect(track.keyframes.allSatisfy { $0.highlight.limbSide == .left && $0.highlight.attackerOnLeft })
        let contact = try #require(track.keyframes.min { $0.highlight.cost < $1.highlight.cost })
        #expect(abs(contact.time - (10 + 3 * step)) < 0.0001)

        // A referee standing still with a hand at the defender's body never
        // wins over the moving arm, however close it is.
        let referee = figure(x: 0.66, moving: [.rightElbow: CGPoint(x: 0.6, y: 0.4), .rightWrist: CGPoint(x: 0.56, y: 0.4)])
        let crowded = frames.map { (time: $0.time, poses: $0.poses + [referee]) }
        let withReferee = try #require(StrikeHighlightRules.track(frames: crowded, time: 10.25, detail: StrikeDetail(technique: .punch), aspect: aspect))
        #expect(withReferee.keyframes.allSatisfy { $0.highlight.limbSide == .left && $0.highlight.attackerOnLeft })
        // A third person on the attacker's side whose own left arm rests on
        // the defender: away from contact the highlight stays on the
        // attacker's arm and never moves across to theirs.
        let bystander = figure(x: 0.15, moving: [.leftElbow: CGPoint(x: 0.36, y: 0.3), .leftWrist: CGPoint(x: 0.54, y: 0.22)])
        let shared = frames.map { (time: $0.time, poses: [bystander] + $0.poses) }
        let followed = try #require(StrikeHighlightRules.track(frames: shared, time: 10.25, detail: detail, aspect: aspect))
        #expect(followed.keyframes.count == 7)
        #expect(followed.keyframes.allSatisfy { abs(($0.highlight.limb.first?.x ?? 1) - 0.38) < 0.001 })
        // Nobody moving: no highlight.
        let still = (0..<5).map { (time: Double($0) * step, poses: [attacker(reach: 0.13), defender]) }
        #expect(StrikeHighlightRules.track(frames: still, time: 2 * step, detail: detail, aspect: aspect) == nil)

        let between = try #require(StrikeHighlightRules.sample(track, at: 10 + 2.5 * step))
        #expect(abs(between.highlight.limb[2].x - (0.4 + 0.105)) < 0.0001)
        #expect(between.opacity == 1)
        #expect(StrikeHighlightRules.sample(track, at: 9) == nil)
        #expect(StrikeHighlightRules.sample(track, at: track.end + 1) == nil)
        let fading = try #require(StrikeHighlightRules.sample(track, at: track.start - StrikeHighlightRules.fade / 2))
        #expect(abs(fading.opacity - 0.5) < 0.0001)

        // A frame where the attacker is lost splits the run; only the part with contact is kept.
        var broken = frames
        broken[1].poses = [defender]
        broken[0].poses = [defender]
        broken.insert((time: 10 - 3 * step, poses: frames[0].poses), at: 0)
        let kept = try #require(StrikeHighlightRules.track(frames: broken, time: 10.25, detail: detail, aspect: aspect))
        #expect(abs(kept.start - (10 + 2 * step)) < 0.0001)
        #expect(StrikeHighlightRules.track(frames: [(time: 1, poses: [defender])], time: 1, detail: detail, aspect: aspect) == nil)
    }

    @Test("Nearby strikes choose contacts inside their own logged windows")
    func nearbyStrikeContacts() throws {
        let defender = figure(x: 0.55)
        func attacker(_ reach: CGFloat) -> StrikeHighlightRules.Pose {
            figure(x: 0.35, moving: [.leftElbow: CGPoint(x: 0.4 + reach / 2, y: 0.28),
                                    .leftWrist: CGPoint(x: 0.4 + reach, y: 0.22)])
        }
        let step = StrikeHighlightRules.step
        let frames = [(time: 10 - step, poses: [attacker(0.02), defender]),
                      (time: 10.0, poses: [attacker(0.1), defender]),
                      (time: 10 + step, poses: [attacker(0.02), defender]),
                      (time: 10.5 - step, poses: [attacker(0.02), defender]),
                      (time: 10.5, poses: [attacker(0.14), defender]),
                      (time: 10.5 + step, poses: [attacker(0.02), defender])]
        let detail = StrikeDetail(technique: .punch, limb: .left, target: .head)
        let first = try #require(StrikeHighlightRules.track(frames: frames, time: 10, detail: detail, aspect: aspect))
        let second = try #require(StrikeHighlightRules.track(frames: frames, time: 10.5, detail: detail, aspect: aspect))
        #expect(abs(first.contact - 10) <= StrikeHighlightRules.contactWindow)
        #expect(abs(second.contact - 10.5) <= StrikeHighlightRules.contactWindow)
        #expect(first.contact == 10 && second.contact == 10.5)
        #expect(first.contact != second.contact)
        let firstContact = try #require(first.keyframes.first { $0.time == first.contact })
        let secondContact = try #require(second.keyframes.first { $0.time == second.contact })
        #expect(secondContact.highlight.cost < firstContact.highlight.cost)

        // Contact at either boundary is allowed; following still uses the
        // wider samples, including frames outside the contact window.
        for time in [9.7, 10.3] {
            let edge = try #require(StrikeHighlightRules.track(frames: Array(frames.prefix(3)), time: time,
                                                               detail: detail, aspect: aspect))
            #expect(edge.contact == 10)
            #expect(edge.keyframes.count == 3)
            #expect(edge.keyframes.contains(where: { $0.time < time - StrikeHighlightRules.contactWindow
                || $0.time > time + StrikeHighlightRules.contactWindow }))
        }
    }

    @Test("A candidate half a second from the logged strike is no match")
    func contactOutsideWindow() throws {
        let defender = figure(x: 0.55)
        let before = figure(x: 0.35, moving: [.leftElbow: CGPoint(x: 0.41, y: 0.28),
                                             .leftWrist: CGPoint(x: 0.42, y: 0.22)])
        let contact = figure(x: 0.35, moving: [.leftElbow: CGPoint(x: 0.47, y: 0.28),
                                              .leftWrist: CGPoint(x: 0.54, y: 0.22)])
        let frames = [(time: 10.5 - StrikeHighlightRules.step, poses: [before, defender]),
                      (time: 10.5, poses: [contact, defender])]
        let detail = StrikeDetail(technique: .punch, limb: .left, target: .head)
        let nearby = try #require(StrikeHighlightRules.track(frames: frames, time: 10.5, detail: detail, aspect: aspect))
        #expect(nearby.contact == 10.5)
        #expect(StrikeHighlightRules.track(frames: frames, time: 10, detail: detail, aspect: aspect) == nil)
        var cache = StrikeHighlightFinder.PoseCache()
        cache.aspect = aspect
        for frame in frames { cache.poses[StrikeHighlightFinder.PoseCache.index(frame.time)] = frame.poses }
        #expect(StrikeHighlightFinder.outcome(times: frames.map(\.time), time: 10, detail: detail, cache: cache) == .noMatch)
        #expect(StrikeHighlightFinder.outcome(times: frames.map(\.time), time: 10.5, detail: detail, cache: cache).track == nearby)
    }

    @Test("The side hint describes the attacker's half of the picture, not their side of the defender")
    func frameSideUsesPictureHalf() throws {
        for x in [CGFloat(0.35), CGFloat(0.6)] {
            let attacker = figure(x: x, moving: [.leftElbow: CGPoint(x: x + 0.09, y: 0.26),
                                                 .leftWrist: CGPoint(x: x + 0.17, y: 0.21)])
            let defender = figure(x: x + 0.2)
            let unhinted = try #require(StrikeHighlightRules.candidates(poses: [attacker, defender], technique: .punch,
                                                                       target: .head, aspect: aspect)
                .first { $0.attacker == attacker && $0.highlight.limbSide == .left })
            let right = try #require(StrikeHighlightRules.candidates(poses: [attacker, defender], technique: .punch,
                                                                    target: .head, frameSide: .right, aspect: aspect)
                .first { $0.attacker == attacker && $0.highlight.limbSide == .left })
            #expect(attacker.centerX < defender.centerX)
            #expect(right.highlight.attackerOnLeft)
            if x > 0.5 {
                #expect(attacker.centerX >= 0.5 && defender.centerX >= 0.5)
                #expect(right.highlight.cost == unhinted.highlight.cost)
            } else {
                #expect(attacker.centerX < 0.5)
                #expect(abs(right.highlight.cost - unhinted.highlight.cost - StrikeHighlightRules.sidePenalty) < 0.0001)
            }
        }
    }

    @Test("Strikes break down into punches and kicks, and a jab then a cross are two strikes")
    func breakdown() {
        func strike(_ id: Int64, _ time: Double, _ detail: String?) -> FightEventRecord {
            FightEventRecord(id: id, videoID: 1, time: time, fighterKey: "a", action: "strike", points: 1,
                             detail: detail, scoringVersion: 3)
        }
        let events = [strike(1, 1, "punch|left|head|left"), strike(2, 1.25, "punch|right|head|left"),
                      strike(3, 1.5, "punch|right|head|left"), strike(4, 5, "kick|right|legs|"),
                      strike(5, 9, "knee||body|"), strike(6, 12, nil), strike(7, 12.25, "punch|||")]
        let fighter = FightScoreDigest.fighters(events: events)[0]
        #expect(fighter.strikes == 7 && fighter.punches == 4 && fighter.kicks == 1)
        #expect(FightScoreDigest.line(fighter, name: "A") == "A: 7 strikes (4 punches, 1 kick)")
        #expect(FightScoreDigest.entries(events: events, fighter: "a", category: .kicks).map(\.summary)
                == ["Strike landed · right kick to the legs"])
        #expect(FightScoreDigest.entries(events: events, fighter: "a", category: .punches).count == 4)
        let parsed = FightAttemptParser.parse(["action": "strike", "at_time": 3.0, "fighter": "a", "technique": "kick",
                                               "limb": "left", "target": "body", "side": "left"],
                                              videoID: 1, start: 0, end: 10, validKeys: ["a"], keyByName: [:])
        #expect(parsed?.detail == "kick|left|body|left")
    }

    @Test("Highlights are saved with the video, and a re-score drops them")
    func storage() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let highlight = StrikeHighlightRules.Highlight(limb: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.25)],
                                                       target: CGPoint(x: 0.32, y: 0.25), radius: 0.06, cost: 0.1,
                                                       limbSide: .left, usesArm: true, attackerOnLeft: true)
        let track = StrikeHighlightRules.Track(keyframes: [.init(time: 4.1, highlight: highlight)], contact: 4.1, aspect: 16.0 / 9)
        try await temp.database.saveStrikeHighlights(videoID: videoID, [
            .init(videoID: videoID, time: 4.25, fighterKey: "a", track: track),
            .init(videoID: videoID, time: 9, fighterKey: "b", track: nil),
        ], generation: 0)
        #expect(try await temp.database.fetchStrikeHighlight(videoID: videoID, time: 9, fighterKey: "b") != nil)
        #expect(try await temp.database.fetchStrikeHighlight(videoID: videoID, time: 9, fighterKey: "a") == nil)
        #expect(try await temp.database.fetchStrikeHighlights(videoID: videoID, overlapping: 20...30).isEmpty)
        let saved = try await temp.database.fetchStrikeHighlights(videoID: videoID)
        #expect(saved.count == 2)
        #expect(saved.first { $0.matches(time: 4.25, fighterKey: "a") }?.track == track)
        #expect(saved.contains { $0.matches(time: 9, fighterKey: "b") && $0.track == nil })
        #expect(!saved.contains { $0.matches(time: 4.25, fighterKey: "b") })
        _ = try await temp.database.replaceFightEventRecords(videoID: videoID, events: [])
        #expect(try await temp.database.fetchStrikeHighlights(videoID: videoID).isEmpty)
        // Work started for events since replaced is refused, not saved.
        #expect(try await temp.database.saveStrikeHighlights(videoID: videoID, [
            .init(videoID: videoID, time: 4.25, fighterKey: "a", track: track),
        ], generation: 0, replacing: true) == false)
        #expect(try await temp.database.fetchStrikeHighlights(videoID: videoID).isEmpty)
        // Events replaced without touching the rows (a sync) hide them too.
        let current = try await temp.database.fightEventGeneration(videoID: videoID)
        #expect(try await temp.database.saveStrikeHighlights(videoID: videoID, [
            .init(videoID: videoID, time: 4.25, fighterKey: "a", track: track),
        ], generation: current))
        #expect(try await temp.database.fetchStrikeHighlights(videoID: videoID).count == 1)
        try await temp.database.advanceFightEventGeneration(videoID: videoID)
        #expect(try await temp.database.fetchStrikeHighlights(videoID: videoID).isEmpty)
    }

    @Test("Marking uses the committed generation and refuses a stale event even at the same time")
    func markingGenerationSnapshot() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let strike = FightEventRecord(id: 0, videoID: videoID, time: 4, fighterKey: "a", action: "strike", points: 1)
        let committed = try #require(try await temp.database.replaceFightEventRecordsReturningGeneration(videoID: videoID, events: [strike]))
        let snapshot = try await temp.database.fightEventsForMarking(videoID: videoID)
        #expect(snapshot.generation == committed)
        #expect(snapshot.events.count == 1 && snapshot.events.allSatisfy { $0.generation == committed })
        let newer = try #require(try await temp.database.replaceFightEventRecordsReturningGeneration(videoID: videoID, events: [strike]))
        let record = StrikeHighlightRecord(videoID: videoID, time: 4, fighterKey: "a", track: nil)
        #expect(try await !temp.database.saveStrikeHighlights(videoID: videoID, [record], generation: committed))
        #expect(try await temp.database.fetchStrikeHighlights(videoID: videoID).isEmpty)
        #expect(try await temp.database.saveStrikeHighlights(videoID: videoID, [record], generation: newer))
        #expect(try await temp.database.fetchStrikeHighlight(videoID: videoID, time: 4, fighterKey: "a", expectedGeneration: committed) == nil)
        #expect(try await temp.database.fetchStrikeHighlight(videoID: videoID, time: 4, fighterKey: "a", expectedGeneration: newer) != nil)
    }

    @Test("Missing in-bounds frames remain retryable, while a complete pose miss is cacheable")
    func incompletePoseExtraction() {
        let times = StrikeHighlightRules.sampleTimes(around: 4, duration: 10)
        var cache = StrikeHighlightFinder.PoseCache()
        cache.aspect = 16.0 / 9
        for time in times { cache.poses[StrikeHighlightFinder.PoseCache.index(time)] = [] }
        let complete = StrikeHighlightFinder.outcome(times: times, time: 4, detail: nil, cache: cache)
        #expect(complete == .noMatch)
        #expect(complete.record(videoID: 1, time: 4, fighterKey: "a") != nil)
        cache.poses[StrikeHighlightFinder.PoseCache.index(times[times.count / 2])] = nil
        let incomplete = StrikeHighlightFinder.outcome(times: times, time: 4, detail: nil, cache: cache)
        #expect(incomplete == .failed)
        #expect(incomplete.record(videoID: 1, time: 4, fighterKey: "a") == nil)
        #expect(StrikeHighlightFinder.outcome(times: [], time: 4, detail: nil, cache: cache) == .failed)
    }

    @Test("With two bare torsos in view, dressed and hidden bodies are not fighters")
    func contenders() {
        var red = figure(x: 0.3), blue = figure(x: 0.6), referee = figure(x: 0.45), hidden = figure(x: 0.7)
        red.bare = 0.8
        blue.bare = 0.5
        referee.bare = 0.02
        hidden.bare = nil
        #expect(StrikeHighlightRules.contenders([red, referee, blue, hidden]) == [red, blue])
        // Someone behind a fighter can read as partly bare: still only the barest two.
        referee.bare = 0.4
        #expect(StrikeHighlightRules.contenders([red, referee, blue]) == [red, blue])
        referee.bare = 0.02
        // One fighter's torso unseen: the dressed one still goes, the unseen one stays.
        #expect(StrikeHighlightRules.contenders([red, referee, hidden]) == [red, hidden])
        // Everyone dressed (a gi, a rash guard), or nothing known: nobody is left out.
        blue.bare = 0.05
        #expect(StrikeHighlightRules.contenders([red, referee, blue]).count == 3)
        #expect(StrikeHighlightRules.contenders([figure(x: 0.3), figure(x: 0.6)]).count == 2)

        // The referee's moving hand at the defender's head is not the strike.
        red.bare = 0.8
        blue.bare = 0.6
        func reaching(_ pose: StrikeHighlightRules.Pose, _ reach: CGFloat, bare: CGFloat) -> StrikeHighlightRules.Pose {
            var pose = pose
            pose.joints[.leftElbow] = CGPoint(x: 0.5 + reach / 2, y: 0.26)
            pose.joints[.leftWrist] = CGPoint(x: 0.5 + reach, y: 0.21)
            pose.bare = bare
            return pose
        }
        let step = StrikeHighlightRules.step
        let frames = [0, 0.04, 0.08].enumerated().map { index, reach in
            (time: Double(index) * step, poses: [red, blue, reaching(referee, reach, bare: 0.02)])
        }
        #expect(StrikeHighlightRules.track(frames: frames, time: step, detail: nil, aspect: aspect) == nil)
        // The same arm on a body that is one of the two fighters is one.
        let undressed = [0, 0.04, 0.08].enumerated().map { index, reach in
            (time: Double(index) * step, poses: [blue, reaching(referee, reach, bare: 0.7)])
        }
        #expect(StrikeHighlightRules.track(frames: undressed, time: step, detail: nil, aspect: aspect) != nil)
    }

    @Test("What is not drawn does not tell two tracks apart")
    func drawable() {
        var highlight = StrikeHighlightRules.Highlight(limb: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.25)],
                                                       target: CGPoint(x: 0.32, y: 0.25), radius: 0.06, cost: 0.1,
                                                       limbSide: .left, usesArm: true, attackerOnLeft: true)
        let one = StrikeHighlightRules.Track(keyframes: [.init(time: 4.1, highlight: highlight)], contact: 4.1, aspect: 16.0 / 9)
        highlight.cost = 0.3
        highlight.limbSide = .right
        var other = StrikeHighlightRules.Track(keyframes: [.init(time: 4.1, highlight: highlight)], contact: 4.2, aspect: 16.0 / 9)
        #expect(StrikeHighlightRules.drawable(one) == StrikeHighlightRules.drawable(other))
        other.keyframes[0].highlight.radius = 0.1
        #expect(StrikeHighlightRules.drawable(one) != StrikeHighlightRules.drawable(other))
    }
}
