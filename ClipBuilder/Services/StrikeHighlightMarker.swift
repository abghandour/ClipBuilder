import Foundation

/// Shared by Mark strikes and Wizard extraction. Runs in the caller's job,
/// off the main actor, and never scores footage or calls an AI provider.
nonisolated enum StrikeHighlightMarker {
    typealias Finder = @Sendable (URL, Int64, [FightEventRecord], Double) async throws -> [StrikeHighlightRecord]

    nonisolated struct Result: Sendable {
        var tracks: [StrikeHighlightRules.Track] = []
        /// Where each saved strike pauses, in source seconds: the tracked
        /// impact, or the scorer's stamp for a strike with no track
        /// (`StrikeHighlightRecord.pauseTime`). `tracks` are reduced to what
        /// is drawn and no longer carry impact times.
        var contacts: [Double] = []
        var complete = false
        var generation: Int64?
        var message = ""
    }

    static let find: Finder = { url, id, events, duration in
        await StrikeHighlightFinder.records(url: url, videoID: id, events: events, duration: duration)
    }

    @concurrent
    @discardableResult
    static func mark(video: VideoRecord, database: Database,
                     isCurrent: @escaping @Sendable () async -> Bool = { true },
                     didSave: @escaping @Sendable () async -> Void = {},
                     marking: @escaping @Sendable (Bool) async -> Void = { _ in },
                     snapshot: WizardStrikeHighlightSnapshot? = nil,
                     finder: @escaping Finder = find,
                     log: @escaping @Sendable (String) -> Void) async throws -> Result {
        let key = FightWorkCoordinator.Key(database: database, videoID: video.id)
        return try await FightWorkCoordinator.shared.withClaim(key: key) {
            guard await isCurrent() else { return Result() }
            // Look again after claiming: another variant may have prepared this source.
            if let generation = try? await database.fightEventGeneration(videoID: video.id),
               let result = await snapshot?.result(for: key, generation: generation) {
                try Task.checkCancellation()
                return await isCurrent() ? result : Result()
            }
            if let snapshot, await !snapshot.beginAttempt(for: key) {
                let result = await savedResult(video: video, database: database)
                if await snapshot.save(result, for: key) { logExhausted(video: video, log: log) }
                try Task.checkCancellation()
                return await isCurrent() ? result : Result()
            }
            await marking(true)
            do {
                var result: Result
                do {
                    result = try await markClaimed(video: video, database: database,
                        isCurrent: isCurrent, didSave: didSave, finder: finder)
                    if let generation = result.generation,
                       try await !database.isFightEventGenerationCurrent(videoID: video.id, generation: generation) {
                        result = await savedResult(video: video, database: database)
                        result.message = "fight events changed after marking; continuing with saved highlights"
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    result = await savedResult(video: video, database: database)
                    result.message = "strike marking incomplete; continuing — \(error.localizedDescription)"
                }
                guard await isCurrent() else {
                    await marking(false)
                    return Result()
                }
                if !result.message.isEmpty { log("\(video.filename): \(result.message)") }
                // Stop still saves partial rows, but never caches completion.
                try Task.checkCancellation()
                if let snapshot, await snapshot.save(result, for: key) { logExhausted(video: video, log: log) }
                await marking(false)
                return result
            } catch {
                await marking(false)
                throw error
            }
        }
    }

    private static func logExhausted(video: VideoRecord, log: @Sendable (String) -> Void) {
        log("\(video.filename): strike marking retry budget exhausted; using saved highlights for the rest of this run")
    }

    /// A fallback read can supply tracks, but cannot turn a failed pass complete.
    private static func savedResult(video: VideoRecord, database: Database) async -> Result {
        guard let state = try? await database.strikeHighlightMarkingState(videoID: video.id) else { return Result() }
        return Result(tracks: state.saved.compactMap(\.track).map(StrikeHighlightRules.drawable),
                      contacts: state.saved.map(\.pauseTime), generation: state.generation)
    }

    private static func markClaimed(video: VideoRecord, database: Database,
                                    isCurrent: @escaping @Sendable () async -> Bool,
                                    didSave: @escaping @Sendable () async -> Void,
                                    finder: Finder) async throws -> Result {
        // Team Sync can replace events without claiming local work. Retry at
        // most twice, always taking the events and generation together again.
        for attempt in 0...2 {
            try Task.checkCancellation()
            guard await isCurrent() else { return Result() }
            let state = try await database.strikeHighlightMarkingState(videoID: video.id)
            try Task.checkCancellation()
            guard await isCurrent() else { return Result() }
            let missing = WizardStrikeHighlights.missingStrikes(events: state.events, saved: state.saved)
            guard !missing.isEmpty else {
                return Result(tracks: state.saved.compactMap(\.track).map(StrikeHighlightRules.drawable),
                    contacts: state.saved.map(\.pauseTime),
                    complete: true, generation: state.generation,
                    message: state.events.isEmpty ? "no fight events; skipping strike marking" : "every strike is already marked")
            }
            let found: [StrikeHighlightRecord]
            do {
                found = try await finder(video.url, video.id, missing, video.duration)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                var result = await savedResult(video: video, database: database)
                result.message = "strike marking failed; continuing — \(error.localizedDescription)"
                return result
            }
            // Stop keeps partial results. A profile change prevents saving even
            // when the finder returns partial results from a cancelled task.
            guard await isCurrent() else { return Result() }
            let accepted = try await database.saveStrikeHighlights(videoID: video.id, found, generation: state.generation,
                                                                  expectedEvents: state.events)
            if accepted {
                await didSave()
                // An accepted save may contain only some strikes. Only this
                // successful post-save read can confirm positive/negative rows
                // for EVERY eligible strike under the current generation/rules.
                let confirmed = try await database.strikeHighlightMarkingState(videoID: video.id)
                let complete = !Task.isCancelled && confirmed.generation == state.generation
                    && WizardStrikeHighlights.missingStrikes(events: confirmed.events, saved: confirmed.saved).isEmpty
                return Result(tracks: confirmed.saved.compactMap(\.track).map(StrikeHighlightRules.drawable),
                    contacts: confirmed.saved.map(\.pauseTime),
                    complete: complete, generation: confirmed.generation,
                    message: "limb and impact marked on \(found.count { $0.track != nil }) of \(missing.count) strike(s)"
                        + (Task.isCancelled ? " before stopping" : complete ? "" : "; marking incomplete"))
            }
            try Task.checkCancellation()
            if attempt == 2 {
                var result = await savedResult(video: video, database: database)
                result.message = "fight events changed during all three marking attempts; continuing with saved highlights"
                return result
            }
        }
        return Result()
    }
}
