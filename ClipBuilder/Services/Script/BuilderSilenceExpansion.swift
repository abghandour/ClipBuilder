import Foundation

@MainActor
enum BuilderSilenceExpansion {
    /// Freeze all target IDs and boundaries before removing anything. Split
    /// tails bind returned IDs; no guessed UUIDs or re-query after repacking.
    static func steps(clips: [TimelineClip], threshold: Double, context: ParserContext) throws -> [BuilderScriptStep] {
        let started = ContinuousClock.now
        guard clips.count <= ScriptRunner.maximumSteps else { throw ScriptError.invalid("Too many clips; narrow the request.") }
        let model = BuilderTimelineModel(mode: .transient)
        context.library.withLayouts { model.seed(document: context.document, scenes: context.library.scenes) }
        var splits: [BuilderScriptStep] = []
        var removals: [BuilderScriptStep] = []
        var expectedSourceCuts: [Double] = []
        for clip in clips.sorted(by: { $0.uid.uuidString < $1.uid.uuidString }) {
            try Task.checkCancellation()
            guard started.duration(to: .now) < .seconds(10) else {
                throw ScriptError.invalid("Silence expansion exceeded ten seconds; narrow the request.")
            }
            guard !clip.bumper, clip.sourceStart != nil else { throw ScriptError.invalid("Silence cuts require a non-bumper clip with source timing.") }
            var query = BuilderQuery(.silences, limit: 200)
            query.clip = clip.uid.uuidString
            // Query source seconds, then apply the requested threshold in screen time.
            query.threshold = max(0.05, min(60, threshold * clip.effectiveSpeed))
            let result = try query.execute(model: model, library: context.library) { value in
                guard let id = UUID(uuidString: value) else { throw ScriptError.invalid("Invalid clip ID.") }
                return id
            }
            guard result.nextOffset == nil else { throw ScriptError.invalid("Too many silence intervals; narrow the request.") }
            guard result.unknown.isEmpty || !result.silences.isEmpty else {
                throw ScriptError.invalid("Silence evidence is unavailable. Prepare transcript timings or silence analysis in the Library first.")
            }
            let spans = result.silences.compactMap(\.timeline).sorted { $0.start < $1.start }
            var merged: [ScriptTimeRange] = []
            for span in spans {
                if let last = merged.last, span.start <= last.end {
                    merged[merged.count - 1].end = max(last.end, span.end)
                } else { merged.append(span) }
            }
            merged = merged.filter { $0.end - $0.start > threshold }
            guard !merged.isEmpty else { continue }
            let start = clip.startTime, end = start + clip.duration
            let boundaries = Set(merged.flatMap { [$0.start, $0.end] }
                .map { TimelinePrecision.speech.rounded($0) }
                .filter { $0 > start + 1e-9 && $0 < end - 1e-9 }).sorted()
            var previous = start
            var reference = clip.uid.uuidString
            for boundary in boundaries {
                guard boundary - previous >= 0.05 - 1e-9, end - boundary >= 0.05 - 1e-9 else {
                    throw ScriptError.invalid("A silence boundary would leave a piece shorter than 50 ms. Adjust the request.")
                }
                let name = "silence_\(splits.count)"
                splits.append(.init(.splitClip(clip: reference, at: boundary, precision: .speech), bind: name))
                expectedSourceCuts.append((clip.sourceStart ?? 0) + (boundary - start) * clip.effectiveSpeed)
                let midpoint = (previous + boundary) / 2
                if merged.contains(where: { $0.start <= midpoint && midpoint < $0.end }) {
                    removals.append(.init(.removeClip(clip: reference)))
                }
                reference = "$\(name).tail"
                previous = boundary
            }
            if merged.contains(where: { $0.start <= (previous + end) / 2 && (previous + end) / 2 < $0.end }) {
                removals.append(.init(.removeClip(clip: reference)))
            }
            guard splits.count + removals.count <= ScriptRunner.maximumSteps else {
                throw ScriptError.invalid("Silence expansion exceeds 200 commands; narrow the request.")
            }
        }
        // Packing can move a later split even before removals (for example a
        // legacy unnormalised lane). Verify the whole expansion on a transient
        // clone and refuse if its actual source boundaries differ from evidence.
        let outcomes = ScriptRunner().run(splits, model: model, library: context.library)
        guard outcomes.count == splits.count else { throw ScriptError.invalid("Silence expansion exceeded run limits.") }
        for (index, outcome) in outcomes.enumerated() {
            if case .refused(let code, let reason) = outcome { throw ScriptError.invalid("Silence expansion refused [\(code)]: \(reason)") }
            guard case .applied(let values, _, _) = outcome,
                  case .object(let object) = values,
                  case .object(let detail) = object["detail"],
                  case .number(let actual) = detail["sourceCut"],
                  abs(actual - expectedSourceCuts[index]) <= 0.001 else {
                throw ScriptError.invalid("Timeline packing moved a silence boundary. Normalise the timeline and run again.")
            }
        }
        return splits + removals
    }
}
