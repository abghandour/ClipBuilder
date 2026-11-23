import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

struct StrikeClipStatusTests {
    private func options() -> WizardOptions {
        var options = WizardOptions()
        options.strikeHighlights = true
        options.strikeImpactFreeze = 0.8
        options.includeIntroBumper = false
        options.includeOutroBumper = false
        options.includeMiddleBumper = false
        options.includeOutro = false
        options.useBRoll = false
        options.manualBRoll = true
        options.useMusic = false
        options.framing = Framing(subject: .original)
        options.allowedTransitions = ["cut"]
        return options
    }

    private func track(_ contact: Double) -> StrikeHighlightRules.Track {
        let highlight = StrikeHighlightRules.Highlight(limb: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.25)],
            target: CGPoint(x: 0.32, y: 0.25), radius: 0.06, cost: 0.1,
            limbSide: .left, usesArm: true, attackerOnLeft: true)
        return .init(keyframes: [.init(time: contact, highlight: highlight)], contact: contact, aspect: 16.0 / 9)
    }

    private func status(_ contacts: [Double], clip: WizardPlanClip = Fixtures.planClip(start: 0, end: 1),
                        options: WizardOptions? = nil) -> StrikeClipStatus {
        StrikeClipStatusRules.status(index: 0, plan: Fixtures.plan(clips: [clip]), scene: Fixtures.scene(),
            sourceType: .fight, saved: .init(tracks: contacts.map(track), contacts: contacts),
            options: options ?? self.options(), xfadeDuration: 0.35)
    }

    @Test("Negative matches show no strike; mark and pause switches are independent")
    func switches() {
        #expect(status([]).line == "No strike found in this clip")
        var options = options()
        options.strikeHighlights = false
        let pauseOnly = status([0.5], options: options)
        #expect(pauseOnly.marks == 0)
        #expect(pauseOnly.pause == .pauses(count: 1, seconds: 0.8))
        #expect(pauseOnly.line == "pause 0.8 s")
        options.strikeHighlights = true
        options.strikeImpactFreeze = nil
        #expect(status([0.5], options: options).pause == .off)
        #expect(status([0.5], options: options).line == "1 mark")
        options.strikeHighlights = false
        #expect(status([0.5], options: options).marks == 0)
        let other = StrikeClipStatusRules.status(index: 0, plan: Fixtures.plan(), scene: Fixtures.scene(),
            sourceType: .podcast, saved: .init(tracks: [track(4)], contacts: [4]), options: self.options(), xfadeDuration: 0.35)
        #expect(other.marks == 0 && other.pause == .off)
    }

    @Test("Start and end skips share the renderer's minimum-piece boundary and speed")
    func boundaries() {
        #expect(status([0.08]).pause == .none(reason: "too close to the clip start"))
        #expect(status([0.92]).pause == .none(reason: "too close to the clip end"))
        #expect(status([0.08, 0.92]).pause == .none(reason: "too close to the clip start or end"))
        #expect(status([0.25, 0.75]).pause == .pauses(count: 2, seconds: 0.8))
        var clip = Fixtures.planClip(start: 0, end: 1)
        clip.speed = 2
        #expect(status([0.3], clip: clip).pause == .none(reason: "too close to the clip start"))
        #expect(status([0.5], clip: clip).pause == .pauses(count: 1, seconds: 0.8))
        clip.speed = 0.5
        #expect(status([0.125], clip: clip).pause == .pauses(count: 1, seconds: 0.8))
    }

    @Test("Marks use drawable deduplication and the burn's fade-overlap range, not contact time")
    func markRanges() {
        let visible = track(0.5)
        var duplicate = visible
        duplicate.contact = 100 // contact is independent of the painted track
        duplicate.keyframes[0].highlight.cost = 5
        let edge = track(-StrikeHighlightRules.fade / 2)
        let saved = StrikeClipStatusRules.Saved(tracks: [visible, duplicate, edge, track(20)], contacts: [0.5])
        let result = StrikeClipStatusRules.status(index: 0, plan: Fixtures.plan(clips: [Fixtures.planClip(start: 0, end: 1)]),
            scene: Fixtures.scene(), sourceType: .fight, saved: saved, options: options(), xfadeDuration: 0.35)
        #expect(result.marks == 2)
        #expect(result.pause == .pauses(count: 1, seconds: 0.8))
    }

    @Test("Known joins, skip reasons and accepted holds agree with real pause preparation",
           arguments: ["cut", "fade", "knife_slash"])
    func engineParity(join: String) throws {
        let scene = Fixtures.scene()
        let clips = [Fixtures.planClip(start: 0, end: 1), Fixtures.planClip(start: 2, end: 3)]
        let plan = Fixtures.plan(clips: clips, transitions: [join])
        let options = options()
        let saved = StrikeClipStatusRules.Saved(tracks: [track(0.7)], contacts: [0.7])
        let cuts = Dictionary(uniqueKeysWithValues: clips.enumerated().map { index, clip in
            (index, WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene],
                settings: .init(), framingPlan: nil))
        })
        let result = StrikeClipStatusRules.status(index: 0, plan: plan, scene: scene, sourceType: .fight,
            saved: saved, options: options, xfadeDuration: 0.35, cut: cuts[0])
        let rendered = WizardStrikePauses.prepare(plan: plan, cuts: cuts, sceneMap: [scene.id: scene],
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: saved.contacts],
            options: options, xfadeDuration: 0.35)
        #expect(result.hasPause == (rendered.timings[0]?.pauses.isEmpty == false))
        if case .none(let reason) = result.pause {
            #expect(rendered.messages.contains { $0.contains(reason) })
            #expect(reason.contains("recipe transition"))
        } else {
            #expect(result.pause == .pauses(count: 1, seconds: 0.8))
            #expect(result.hardCutJoin == (join == "fade"))
            #expect(rendered.joins.transitions == ["cut"])
        }
    }

    @Test("Dub, bumpers and composition use skipReason verbatim", arguments: ["dub", "intro", "outro", "middle", "composition", "broll"])
    func unsupported(kind: String) throws {
        let scene = Fixtures.scene()
        var clip = Fixtures.planClip(start: 0, end: 1)
        var options = options()
        var cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene], settings: .init(), framingPlan: nil)
        switch kind {
        case "dub": options.dubLanguage = "es"
        case "intro": options.includeIntroBumper = true
        case "outro": options.includeOutroBumper = true
        case "middle": options.includeMiddleBumper = true
        case "composition": clip.layout = "Two areas"
        default: cut.videoTrack[0].role = .cutaway
        }
        let plan = Fixtures.plan(clips: [clip])
        let skip = WizardStrikePauses.skipReason(index: 0, plan: plan, cut: cut,
            scene: scene, sourceType: .fight, options: options)
        let result = StrikeClipStatusRules.status(index: 0, plan: plan, scene: scene, sourceType: .fight,
            saved: .init(tracks: [track(0.5)], contacts: [0.5]), options: options, xfadeDuration: 0.35, cut: cut)
        if kind == "composition" {
            #expect(skip == nil)
            #expect(result.pause == .pauses(count: 1, seconds: 0.8))
        } else {
            let reason = try #require(skip)
            #expect(result.pause == .none(reason: reason))
        }
    }

    @Test("Hold length, duplicate contacts and cap stay identical to engine timing")
    func capAndSeconds() {
        let clip = Fixtures.planClip(start: 0, end: 10)
        let contacts = [0.1, 0.5, 0.5] + Array(stride(from: 1.0, through: 9.5, by: 0.5))
        var options = options()
        options.strikeImpactFreeze = 100
        let result = status(contacts, clip: clip, options: options)
        let timing = WizardStrikePauses.timing(for: clip, contacts: contacts, seconds: options.strikeImpactFreeze)
        #expect(result.pause == .pauses(count: timing.pauses.count, seconds: 5))
        #expect(result.filteredContacts == timing.filteredContacts)
        #expect(timing.pauses.count == StrikeFreezeRules.maximumContacts)
    }

    @Test("A composed framing choice shares one pause across its pictures")
    func framing() {
        var options = options()
        options.framing = Framing(subject: .layout)
        #expect(status([0.5], options: options).pause
            == .pauses(count: 1, seconds: 0.8))
    }

    private func request() -> MiniStrikeStatusRequest {
        let scene = Fixtures.scene()
        let previews = [WizardPreviewClip(id: "fight-1", title: "First", scene: scene, start: 0, end: 1),
                        WizardPreviewClip(id: "fight-2", title: "Second", scene: scene, start: 2, end: 3)]
        return .init(dataKey: "profile:video:revision", videoID: scene.videoID, isFight: true,
                     clips: MiniStrikeStatusRequest.clips(previews, runs: []), options: options(), xfadeDuration: 0.35)
    }

    @Test("Random joins remain conditional in rows and the summary; one allowed effect is known")
    func random() throws {
        var request = request()
        request.options.transitionChoice = "random"
        request.options.allowedTransitions = ["fade", "knife_slash"]
        let saved = StrikeClipStatusRules.Saved(tracks: [track(0.7), track(2.5)], contacts: [0.7, 2.5])
        let result = request.evaluate(saved: saved)
        let first = try #require(result.statuses["fight-1"])
        #expect(first.hasPause && first.conditionalTransition)
        #expect(first.line.contains("may be skipped for a recipe transition (Random)"))
        #expect(first.line.contains("join may become a hard cut (Random)"))
        #expect(result.summary == "Marks on 2 of 2 clips · pauses on up to 2 (Random)")
        request.options.allowedTransitions = ["fade"]
        let known = try #require(request.evaluate(saved: saved).statuses["fight-1"])
        #expect(known.hasPause && !known.conditionalTransition && known.hardCutJoin)
        #expect(known.line.contains("neighbouring join is a hard cut"))
        request.options.allowedTransitions = ["fade", "wipeleft"]
        let ordinary = request.evaluate(saved: saved)
        #expect(ordinary.statuses["fight-1"]?.conditionalTransition == false)
        #expect(ordinary.statuses["fight-1"]?.unknownTransition == true)
        #expect(ordinary.summary == "Marks on 2 of 2 clips · pauses on 2")
        request.options.allowedTransitions = ["knife_slash", "zoom_punch"]
        let recipes = request.evaluate(saved: saved)
        #expect(recipes.statuses["fight-1"]?.pause == .none(reason: "recipe transition joins need the unsplit cut"))
        #expect(recipes.summary == "Marks on 2 of 2 clips · pauses on 0")
        request.options.allowedTransitions = ["cut"]
        #expect(request.evaluate(saved: saved).statuses["fight-1"]?.hasPause == true)
    }

    @Test("Both sides report the shared cut, including a neighbour with no saved contacts")
    func neighbourStatus() throws {
        var request = request()
        request.options.transitionChoice = "fade"
        request.options.allowedTransitions = ["fade"]
        let result = request.evaluate(saved: .init(tracks: [track(0.7)], contacts: [0.7]))
        let first = try #require(result.statuses["fight-1"])
        let next = try #require(result.statuses["fight-2"])
        #expect(first.pause == .pauses(count: 1, seconds: 0.8))
        #expect(first.hardCutJoin && next.hardCutJoin)
        #expect(next.pause == .none(reason: StrikeClipStatus.noStrike))
        #expect(next.line.contains("neighbouring join is a hard cut"))
        #expect(!first.unknownTransition && !next.unknownTransition)
    }

    @Test("Trim, order, seconds, settings and metadata revisions invalidate the input snapshot")
    func changes() {
        let original = request()
        var changed = original
        changed.clips[0].preview.start = 0.6
        changed.clips[0].plan.start = 0.6
        #expect(changed != original)
        let saved = StrikeClipStatusRules.Saved(tracks: [track(0.7)], contacts: [0.7])
        #expect(changed.evaluate(saved: saved).statuses["fight-1"]?.pause == .none(reason: "too close to the clip start"))
        changed = original
        changed.clips.reverse()
        #expect(changed != original)
        changed = original
        changed.options.strikeImpactFreeze = 1.2
        #expect(changed != original)
        #expect(changed.evaluate(saved: saved).statuses["fight-1"]?.pause == .pauses(count: 1, seconds: 1.2))
        changed.options.strikeHighlights = false
        #expect(changed.evaluate(saved: saved).statuses["fight-1"]?.marks == 0)
        changed.options.strikeImpactFreeze = nil
        #expect(!changed.visible && changed.evaluate(saved: saved).statuses.isEmpty)
        changed = original
        changed.isFight = false
        #expect(!changed.visible)
        changed = original
        changed.dataKey += ":new"
        #expect(changed != original)
        // The Footage adapter uses this exact ID, not its position or range.
        #expect(original.evaluate(saved: saved).statuses[MiniReelRules.clipID(kind: .fightMetrics, itemID: 1)]?.marks == 1)
    }

    @Test("Incomplete marking is not presented as a confirmed negative")
    func incomplete() throws {
        let result = request().evaluate(saved: .init(complete: false))
        let first = try #require(result.statuses["fight-1"])
        #expect(first.pause == .none(reason: "strike marking not finished"))
        #expect(first.markingIncomplete)
        #expect(result.summary.contains("saved so far"))
    }

    @Test("Status uses paced source ranges and does not promise an unloaded Highlight plan")
    func pacingAndUnloadedTake() throws {
        var request = request()
        request.options.formatPreset = "custom"
        request.options.pacing.cadence = .twoSeconds
        request.clips = [request.clips[0]]
        request.clips[0].preview.end = 10
        request.clips[0].plan.end = 10
        let saved = StrikeClipStatusRules.Saved(tracks: [track(8)], contacts: [8])
        let paced = try #require(request.evaluate(saved: saved).statuses["fight-1"])
        #expect(paced.marks == 0 && !paced.hasPause)
        request.clips[0].plan.reason = "keep end"
        let end = try #require(request.evaluate(saved: saved).statuses["fight-1"])
        #expect(end.marks == 1)
        #expect(end.pause == .none(reason: "too close to the clip start"))
        request.clips[0].planAvailable = false
        #expect(request.evaluate(saved: saved).statuses["fight-1"]?.unavailableReason != nil)
    }

    @Test("Database snapshot keeps raw contacts, negative rows and current generation")
    func snapshot() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        try await temp.database.replaceFightEvents(videoID: videoID, events: [
            (time: 0.5, fighterKey: "a", action: "strike", points: 1),
            (time: 2.5, fighterKey: "a", action: "strike", points: 1),
        ])
        let generation = try await temp.database.fightEventGeneration(videoID: videoID)
        _ = try await temp.database.saveStrikeHighlights(videoID: videoID, [
            .init(videoID: videoID, time: 0.5, fighterKey: "a", track: track(0.55)),
            .init(videoID: videoID, time: 2.5, fighterKey: "a", track: nil),
        ], generation: generation)
        let saved = try await temp.database.strikeClipStatusSnapshot(videoID: videoID)
        #expect(saved.complete && saved.tracks.count == 1)
        // The unmarked strike pauses at the scorer's stamp.
        #expect(saved.contacts == [0.55, 2.5])
        #expect(StrikeHighlightRules.drawable(saved.tracks[0]).contact == 0)
        try await temp.database.advanceFightEventGeneration(videoID: videoID)
        let stale = try await temp.database.strikeClipStatusSnapshot(videoID: videoID)
        #expect(stale.tracks.isEmpty && stale.contacts.isEmpty && !stale.complete)
    }
}
