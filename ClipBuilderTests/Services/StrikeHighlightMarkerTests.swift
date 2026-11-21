import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

struct StrikeHighlightMarkerTests {
    private func fixture() async throws -> (TempDatabase, VideoRecord, FightEventRecord) {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let video = try #require(try await temp.database.video(id: id))
        let event = FightEventRecord(id: 0, videoID: id, time: 4, fighterKey: "a", action: "strike", points: 1)
        try await temp.database.replaceFightEventRecords(videoID: id, events: [event])
        return (temp, video, event)
    }

    @Test("A refused generation is re-read and retried; only the accepted save notifies")
    func generationRetry() async throws {
        let (temp, video, event) = try await fixture()
        let database = temp.database
        let calls = Mutex(0), saves = Mutex(0)
        let messages = Mutex<[String]>([])
        let snapshot = WizardStrikeHighlightSnapshot()
        var replacement = event
        replacement.time = 7
        let newer = replacement
        let result = try await StrikeHighlightMarker.mark(video: video, database: database,
            didSave: { saves.withLock { $0 += 1 } }, snapshot: snapshot, finder: { _, id, events, _ in
                let call = calls.withLock { $0 += 1; return $0 }
                if call == 1 { try await database.replaceFightEventRecords(videoID: id, events: [newer]) }
                return events.map { .init(videoID: id, time: $0.time, fighterKey: $0.fighterKey, track: nil) }
            }, log: { line in messages.withLock { $0.append(line) } })
        let saved = try await database.fetchStrikeHighlights(videoID: video.id)
        let generation = try await database.fightEventGeneration(videoID: video.id)
        #expect(result.complete)
        #expect(calls.withLock { $0 } == 2)
        #expect(saves.withLock { $0 } == 1)
        #expect(messages.withLock { $0.count } == 1)
        #expect(saved.count == 1 && saved.contains(where: { $0.time == 7 }))
        #expect(try await database.fetchStrikeHighlight(videoID: video.id, time: 7, fighterKey: "a", expectedGeneration: generation) != nil)
        // A saved negative match is complete; another call does not search or notify.
        try await StrikeHighlightMarker.mark(video: video, database: database,
            didSave: { saves.withLock { $0 += 1 } }, snapshot: snapshot, finder: { _, _, _, _ in
                Issue.record("Already marked strikes must not be searched")
                return []
            }, log: { _ in })
        #expect(saves.withLock { $0 } == 1)
    }

    @Test("Generation churn stops after the initial attempt and two retries")
    func boundedRetries() async throws {
        let (temp, video, event) = try await fixture()
        let database = temp.database
        let calls = Mutex(0), saves = Mutex(0)
        let messages = Mutex<[String]>([])
        let result = try await StrikeHighlightMarker.mark(video: video, database: database,
            didSave: { saves.withLock { $0 += 1 } }, finder: { _, id, _, _ in
                calls.withLock { $0 += 1 }
                try await database.replaceFightEventRecords(videoID: id, events: [event])
                return [.init(videoID: id, time: event.time, fighterKey: event.fighterKey, track: nil)]
            }, log: { line in messages.withLock { $0.append(line) } })
        #expect(!result.complete)
        #expect(calls.withLock { $0 } == 3)
        #expect(saves.withLock { $0 } == 0)
        #expect(try await database.fetchStrikeHighlights(videoID: video.id).isEmpty)
        #expect(messages.withLock { $0.count == 1 && $0.contains(where: { $0.contains("three marking attempts") }) })
    }

    @Test("A profile becoming invalid during finding prevents all saves")
    func profileSwitch() async throws {
        let (temp, video, event) = try await fixture()
        let current = Mutex(true), saves = Mutex(0)
        try await StrikeHighlightMarker.mark(video: video, database: temp.database,
            isCurrent: { current.withLock { $0 } }, didSave: { saves.withLock { $0 += 1 } },
            finder: { _, id, _, _ in
                current.withLock { $0 = false }
                return [.init(videoID: id, time: event.time, fighterKey: event.fighterKey, track: nil)]
            }, log: { _ in })
        #expect(try await temp.database.fetchStrikeHighlights(videoID: video.id).isEmpty)
        #expect(saves.withLock { $0 } == 0)
    }

    @Test("An ordinary Stop saves partial results, notifies once, and releases its claim")
    func partialCancellation() async throws {
        let (temp, video, event) = try await fixture()
        let database = temp.database
        var second = event
        second.time = 7
        try await database.replaceFightEventRecords(videoID: video.id, events: [event, second])
        let entered = StrikeMarkingGate(), finish = StrikeMarkingGate()
        let saves = Mutex(0)
        let snapshot = WizardStrikeHighlightSnapshot()
        let worker = Task {
            try await StrikeHighlightMarker.mark(video: video, database: database,
                didSave: { saves.withLock { $0 += 1 } }, snapshot: snapshot, finder: { _, id, _, _ in
                    await entered.open()
                    await finish.wait()
                    return [.init(videoID: id, time: event.time, fighterKey: event.fighterKey, track: nil)]
                }, log: { _ in })
        }
        await entered.wait()
        worker.cancel()
        await finish.open()
        do {
            _ = try await worker.value
            Issue.record("Stop should propagate cancellation after the partial save")
        } catch is CancellationError {}
        #expect(try await database.fetchStrikeHighlights(videoID: video.id).count == 1)
        #expect(saves.withLock { $0 } == 1)
        let acquired = try await FightWorkCoordinator.shared.withClaim(key: .init(database: database, videoID: video.id)) { true }
        #expect(acquired)
        let generation = try await database.fightEventGeneration(videoID: video.id)
        #expect(await snapshot.result(for: .init(database: database, videoID: video.id), generation: generation) == nil)
        let retried = try await StrikeHighlightMarker.mark(video: video, database: database,
            snapshot: snapshot, finder: { _, id, events, _ in
                #expect(events.map(\.time) == [7])
                return events.map { .init(videoID: id, time: $0.time, fighterKey: $0.fighterKey, track: nil) }
            }, log: { _ in })
        #expect(retried.complete)
    }

    @Test("A failed finder reports one file and does not stop another video's marking")
    func finderFailure() async throws {
        let (temp, video, _) = try await fixture()
        let (otherTemp, otherVideo, _) = try await fixture()
        let messages = Mutex<[String]>([]), saves = Mutex(0)
        let inputs = [(temp.database, video, true), (otherTemp.database, otherVideo, false)]
        _ = try await BoundedConcurrency.map(inputs, limit: 2) { _, input in
            try await StrikeHighlightMarker.mark(video: input.1, database: input.0,
                didSave: { saves.withLock { $0 += 1 } }, finder: { _, id, events, _ in
                    if input.2 { throw FinderFailure() }
                    return events.map { .init(videoID: id, time: $0.time, fighterKey: $0.fighterKey, track: nil) }
                }, log: { line in messages.withLock { $0.append(line) } })
        }
        #expect(messages.withLock { $0.count == 2 && $0.contains(where: { $0.contains("strike marking failed") }) })
        #expect(saves.withLock { $0 } == 1)
        #expect(try await temp.database.fetchStrikeHighlights(videoID: video.id).isEmpty)
        #expect(try await otherTemp.database.fetchStrikeHighlights(videoID: otherVideo.id).count == 1)
    }

    @Test("Reel variants share the drawable snapshot captured after marking")
    func snapshotAcrossVariants() async throws {
        let (temp, video, event) = try await fixture()
        let database = temp.database
        let highlight = StrikeHighlightRules.Highlight(limb: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.25)],
            target: CGPoint(x: 0.32, y: 0.25), radius: 0.06, cost: 0.1,
            limbSide: .left, usesArm: true, attackerOnLeft: true)
        let track = StrikeHighlightRules.Track(keyframes: [.init(time: 4, highlight: highlight)], contact: 4, aspect: 16.0 / 9)
        let snapshots = Mutex<[[StrikeHighlightRules.Track]]>([]), calls = Mutex(0)
        try await WizardReelBatch.run(count: 2, render: { _ in
            let snapshot = try #require(WizardStrikeHighlightSnapshot.current)
            let result = try await StrikeHighlightMarker.mark(video: video, database: database, snapshot: snapshot,
                finder: { _, id, _, _ in
                    calls.withLock { $0 += 1 }
                    return [.init(videoID: id, time: event.time, fighterKey: event.fighterKey, track: track)]
                }, log: { _ in })
            #expect(result.complete)
            snapshots.withLock { $0.append(result.tracks) }
            return nil
        }, finishEmit: { _, _ in })
        #expect(calls.withLock { $0 } == 1)
        #expect(snapshots.withLock { $0 == [[StrikeHighlightRules.drawable(track)], [StrikeHighlightRules.drawable(track)]] })
    }

    @Test("A run reuses current marks but searches again after the source generation moves")
    func snapshotGenerationChanges() async throws {
        let (temp, video, event) = try await fixture()
        let snapshot = WizardStrikeHighlightSnapshot()
        let calls = Mutex(0), messages = Mutex<[String]>([])
        let finder: StrikeHighlightMarker.Finder = { _, id, events, _ in
            calls.withLock { $0 += 1 }
            return events.map { .init(videoID: id, time: $0.time, fighterKey: $0.fighterKey, track: nil) }
        }
        for _ in 0..<2 {
            try await StrikeHighlightMarker.mark(video: video, database: temp.database, snapshot: snapshot,
                finder: finder, log: { line in messages.withLock { $0.append(line) } })
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(messages.withLock { $0.count } == 1)

        var replacement = event
        replacement.time = 7
        try await temp.database.replaceFightEventRecords(videoID: video.id, events: [replacement])
        for _ in 0..<2 {
            try await StrikeHighlightMarker.mark(video: video, database: temp.database, snapshot: snapshot,
                finder: finder, log: { line in messages.withLock { $0.append(line) } })
        }
        #expect(calls.withLock { $0 } == 2)
        #expect(messages.withLock { $0.count } == 2)
        let saved = try await temp.database.fetchStrikeHighlights(videoID: video.id)
        #expect(saved.count == 1 && saved.contains(where: { $0.time == 7 }))
    }

    @Test("A strike with no limb track still pauses, at the scorer's stamp")
    func unmarkedStrikePauses() async throws {
        let (temp, video, event) = try await fixture()
        let generation = try await temp.database.fightEventGeneration(videoID: video.id)
        let record = StrikeHighlightRecord(videoID: video.id, time: event.time, fighterKey: event.fighterKey, track: nil)
        #expect(record.pauseTime == event.time)
        try await temp.database.saveStrikeHighlights(videoID: video.id, [record], generation: generation)
        let saved = try await temp.database.strikeClipStatusSnapshot(videoID: video.id)
        #expect(saved.tracks.isEmpty && saved.contacts == [event.time])
    }

    @Test("Already-current saved marks enter the run snapshot without invoking the finder")
    func snapshotAlreadyCurrent() async throws {
        let (temp, video, event) = try await fixture()
        let generation = try await temp.database.fightEventGeneration(videoID: video.id)
        try await temp.database.saveStrikeHighlights(videoID: video.id,
            [.init(videoID: video.id, time: event.time, fighterKey: event.fighterKey, track: nil)], generation: generation)
        let snapshot = WizardStrikeHighlightSnapshot()
        let messages = Mutex<[String]>([])
        for _ in 0..<2 {
            try await StrikeHighlightMarker.mark(video: video, database: temp.database, snapshot: snapshot,
                finder: { _, _, _, _ in
                    Issue.record("Current saved marks must not invoke the finder")
                    return []
                }, log: { line in messages.withLock { $0.append(line) } })
        }
        #expect(messages.withLock { $0.count == 1 && $0.contains(where: { $0.contains("already marked") }) })
    }

    @Test("Incomplete marking retries only omitted strikes; saved positive and negative rows stay complete")
    func incompleteRetriesOnlyMissing() async throws {
        let (temp, video, event) = try await fixture()
        var second = event
        second.time = 7
        var third = event
        third.time = 9
        try await temp.database.replaceFightEventRecords(videoID: video.id, events: [event, second, third])
        let highlight = StrikeHighlightRules.Highlight(limb: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.25)],
            target: CGPoint(x: 0.32, y: 0.25), radius: 0.06, cost: 0.1,
            limbSide: .left, usesArm: true, attackerOnLeft: true)
        let track = StrikeHighlightRules.Track(keyframes: [.init(time: 4, highlight: highlight)], contact: 4, aspect: 16.0 / 9)
        let requests = Mutex<[[Double]]>([])
        let snapshot = WizardStrikeHighlightSnapshot()
        let key = FightWorkCoordinator.Key(database: temp.database, videoID: video.id)
        let finder: StrikeHighlightMarker.Finder = { _, id, events, _ in
            let call = requests.withLock { $0.append(events.map(\.time)); return $0.count }
            // Simulate a failed frame/pose read for the last strike on pass one.
            return events.filter { call > 1 || $0.time != 9 }.map {
                .init(videoID: id, time: $0.time, fighterKey: $0.fighterKey, track: $0.time == 4 ? track : nil)
            }
        }
        let first = try await StrikeHighlightMarker.mark(video: video, database: temp.database,
            snapshot: snapshot, finder: finder, log: { _ in })
        #expect(!first.complete)
        #expect(first.tracks == [StrikeHighlightRules.drawable(track)])
        let generation = try #require(first.generation)
        #expect(await snapshot.result(for: key, generation: generation) == nil)
        let secondResult = try await StrikeHighlightMarker.mark(video: video, database: temp.database,
            snapshot: snapshot, finder: finder, log: { _ in })
        #expect(secondResult.complete)
        #expect(secondResult.tracks == first.tracks)
        #expect(requests.withLock { $0 } == [[4, 7, 9], [9]])
        for _ in 0..<4 {
            let result = try await StrikeHighlightMarker.mark(video: video, database: temp.database,
                snapshot: snapshot, finder: finder, log: { _ in })
            #expect(result.complete)
        }
        #expect(requests.withLock { $0.count } == 2)
    }

    @Test("A generation replaced after saving is incomplete until the new strikes are confirmed")
    func postSaveGenerationChange() async throws {
        let (temp, video, event) = try await fixture()
        let database = temp.database
        var replacement = event
        replacement.time = 7
        let newer = replacement
        let snapshot = WizardStrikeHighlightSnapshot()
        let first = try await StrikeHighlightMarker.mark(video: video, database: database,
            didSave: {
                do { try await database.replaceFightEventRecords(videoID: video.id, events: [newer]) }
                catch { Issue.record("Fixture replacement failed: \(error)") }
            }, snapshot: snapshot, finder: { _, id, events, _ in
                events.map { .init(videoID: id, time: $0.time, fighterKey: $0.fighterKey, track: nil) }
            }, log: { _ in })
        #expect(!first.complete)
        let retried = try await StrikeHighlightMarker.mark(video: video, database: database,
            snapshot: snapshot, finder: { _, id, events, _ in
                #expect(events.map(\.time) == [7])
                return events.map { .init(videoID: id, time: $0.time, fighterKey: $0.fighterKey, track: nil) }
            }, log: { _ in })
        #expect(retried.complete)
    }

    @Test("Failed and omitted marking retry twice per run, stop, and log budget exhaustion once", arguments: [false, true])
    func incompleteRetryBudget(throwsError: Bool) async throws {
        let (temp, video, _) = try await fixture()
        let snapshot = WizardStrikeHighlightSnapshot()
        let calls = Mutex(0), messages = Mutex<[String]>([])
        let finder: StrikeHighlightMarker.Finder = { _, _, _, _ in
            calls.withLock { $0 += 1 }
            if throwsError { throw FinderFailure() }
            return []
        }
        for request in 0..<7 {
            let result = try await StrikeHighlightMarker.mark(video: video, database: temp.database,
                snapshot: snapshot, finder: finder, log: { line in messages.withLock { $0.append(line) } })
            #expect(!result.complete)
            #expect(calls.withLock { $0 } == min(request + 1, 1 + WizardStrikeHighlightSnapshot.incompleteRetryLimit))
        }
        #expect(messages.withLock { $0.filter { $0.contains("retry budget exhausted") }.count } == 1)
        // A new run gets a new budget, without any durable revision or schema state.
        _ = try await StrikeHighlightMarker.mark(video: video, database: temp.database,
            snapshot: WizardStrikeHighlightSnapshot(), finder: finder, log: { _ in })
        #expect(calls.withLock { $0 } == 2 + WizardStrikeHighlightSnapshot.incompleteRetryLimit)
    }

    @Test("Exhausted marking keeps drawable saved tracks and does not restart on generation churn")
    func exhaustedSavedTracks() async throws {
        let (temp, video, event) = try await fixture()
        var second = event
        second.time = 7
        try await temp.database.replaceFightEventRecords(videoID: video.id, events: [event, second])
        let highlight = StrikeHighlightRules.Highlight(limb: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.25)],
            target: CGPoint(x: 0.32, y: 0.25), radius: 0.06, cost: 0.1,
            limbSide: .left, usesArm: true, attackerOnLeft: true)
        let track = StrikeHighlightRules.Track(keyframes: [.init(time: 4, highlight: highlight)], contact: 4, aspect: 16.0 / 9)
        let snapshot = WizardStrikeHighlightSnapshot()
        let calls = Mutex(0), messages = Mutex<[String]>([])
        let finder: StrikeHighlightMarker.Finder = { _, id, events, _ in
            calls.withLock { $0 += 1 }
            return events.filter { $0.time == 4 }.map {
                .init(videoID: id, time: $0.time, fighterKey: $0.fighterKey, track: track)
            }
        }
        for _ in 0..<6 {
            let result = try await StrikeHighlightMarker.mark(video: video, database: temp.database,
                snapshot: snapshot, finder: finder, log: { line in messages.withLock { $0.append(line) } })
            #expect(!result.complete)
            #expect(result.tracks == [StrikeHighlightRules.drawable(track)])
        }
        try await temp.database.replaceFightEventRecords(videoID: video.id, events: [event])
        let result = try await StrikeHighlightMarker.mark(video: video, database: temp.database,
            snapshot: snapshot, finder: finder, log: { line in messages.withLock { $0.append(line) } })
        #expect(!result.complete && result.tracks.isEmpty)
        #expect(calls.withLock { $0 } == 1 + WizardStrikeHighlightSnapshot.incompleteRetryLimit)
        #expect(messages.withLock { $0.filter { $0.contains("retry budget exhausted") }.count } == 1)
    }

    @Test("Wizard save notifications refresh previews and keep Sources disabled until marking finishes")
    @MainActor
    func ownerCallbacks() async throws {
        let (temp, video, _) = try await fixture()
        let settings = AppSettings()
        let profile = Fixtures.brand(name: "Highlight callbacks")
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai), database: temp.database)
        let context = store.wizardStrikeHighlightOwner.context(database: temp.database)
        let revision = store.strikeHighlightRevision
        store.fightScoringJobsInFlight.insert(video.id)
        await context.marking(video.id, true)
        store.fightScoringJobsInFlight.remove(video.id)
        #expect(store.fightScoringInFlight.contains(video.id))
        await context.marking(video.id, false)
        #expect(!store.fightScoringInFlight.contains(video.id))
        try await StrikeHighlightMarker.mark(video: video, database: temp.database,
            isCurrent: context.isCurrent, didSave: context.didSave,
            marking: { await context.marking(video.id, $0) }, finder: { _, id, events, _ in
                events.map { .init(videoID: id, time: $0.time, fighterKey: $0.fighterKey, track: nil) }
            }, log: { _ in })
        #expect(store.strikeHighlightRevision == revision + 1)
        #expect(!store.fightScoringInFlight.contains(video.id))
        // A generation change invalidates the captured callbacks even when
        // the database object is still the same (including switch away/back).
        store.profileGeneration &+= 1
        #expect(await !context.isCurrent())
        await context.didSave()
        await context.marking(video.id, true)
        #expect(store.strikeHighlightRevision == revision + 1)
        #expect(!store.fightScoringInFlight.contains(video.id))
        let current = store.wizardStrikeHighlightOwner.context(database: temp.database)
        let other = try await TempDatabase()
        store.database = other.database
        #expect(await !current.isCurrent())
        await current.didSave()
        #expect(store.strikeHighlightRevision == revision + 1)
    }

    private nonisolated struct FinderFailure: Error {}
}

/// Explicit gates keep cancellation tests independent of wall-clock timing.
actor StrikeMarkingGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}
