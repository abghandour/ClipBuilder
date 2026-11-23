import Foundation

nonisolated enum PreviewDubPlan {
    struct Block: Sendable, Equatable {
        var lineID: UUID
        var url: URL
        var start: Double
        var duration: Double
        var sourceStart: Double
        var stretch: Double
        var fadeIn: Double
        var fadeOut: Double
        var end: Double { start + duration }
    }

    struct Plan: Sendable, Equatable {
        var blocks: [Block] = []
        var duckRanges: [Range<Double>] = []
        var originalLevel: Double = 1
        var replaceOriginal = false
        var sourceSpan: Range<Double> = 0..<0
        var bumpers: [Range<Double>] = []
        var envelopes: [DubSourceEnvelope.Envelope] = []
        static let empty = Plan()
    }

    static func make(document: TimelineDocument, enabled: Bool = true,
                     missingAudio: Set<String> = [], directory: URL = DubSynthesizer.cacheDirectory) -> Plan {
        guard enabled, let settings = document.dub, settings.enabled else { return .empty }
        let freezes = DubFreezes.intervals(in: document)
        let end = document.videoTrack.map { $0.startTime + $0.duration }.max() ?? 0
        let bumpers = DubSourceEnvelope.bumpers(in: document)
        var blocks: [Block] = []
        for line in document.dubLines ?? [] {
            guard let name = line.audio, !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent,
                  !missingAudio.contains(name) else { continue }
            // Synthesis already baked line.rate into the cached audio; export
            // applies only this atempo multiplier, clamped to the same range.
            let stretch = min(1.15, max(1, line.stretch))
            for segment in DubPauseRules.layout(line, freezes: freezes).segments {
                let lower = max(0, segment.start), upper = min(end, segment.start + segment.duration)
                guard upper > lower else { continue }
                let duration = upper - lower
                blocks.append(Block(lineID: line.id, url: directory.appendingPathComponent(name),
                    start: lower, duration: duration,
                    sourceStart: (segment.audioStart + lower - segment.start) * stretch,
                    stretch: stretch, fadeIn: min(duration / 2, segment.fadeIn),
                    fadeOut: min(duration / 2, segment.fadeOut)))
            }
        }
        guard !blocks.isEmpty else { return .empty }
        blocks.sort { $0.start < $1.start }
        let ranges = DubSourceEnvelope.sourceRanges(lines: document.dubLines ?? [], settings: settings,
            freezes: freezes, bumpers: bumpers)
        var plan = Plan(blocks: blocks, originalLevel: ranges.level,
            replaceOriginal: ranges.replace, sourceSpan: 0..<max(0, end), bumpers: ranges.replacementExclusions,
            envelopes: ranges.duck)
        plan.duckRanges = duckRanges(plan: plan, played: blocks)
        return plan
    }

    static func duckRanges(plan: Plan, played: [Block]) -> [Range<Double>] {
        guard !played.isEmpty else { return [] }
        if plan.replaceOriginal {
            return TimelineDocument.subtracting(plan.bumpers, from: plan.sourceSpan)
        }
        return DubFreezes.merged(plan.envelopes.map { $0.attack..<$0.release })
    }

    typealias Ramp = DubSourceEnvelope.Ramp

    static func ramps(plan: Plan, within span: Range<Double>, volume: Double, bumper: Bool? = nil) -> [Ramp] {
        guard !plan.blocks.isEmpty else { return [] }
        // The composer knows the source of each segment. Never exempt footage
        // merely because its span intersects a bumper's time range.
        return DubSourceEnvelope.ramps(envelopes: plan.envelopes,
            replace: plan.replaceOriginal && bumper != true,
            level: plan.originalLevel, bumpers: bumper == nil ? plan.bumpers : [], within: span, volume: volume)
    }
}
