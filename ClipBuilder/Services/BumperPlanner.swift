import Foundation

/// Shared, pure timeline insertion. Callers supply catalog snapshots; tests
/// supply a generator without changing production's system randomness.
nonisolated struct BumperPlanner {
    static func apply(to document: inout TimelineDocument, bumpers: [BumperAsset],
                      options: WizardOptions) -> [String] {
        var generator = SystemRandomNumberGenerator()
        return apply(to: &document, bumpers: bumpers, options: options, using: &generator)
    }

    static func apply<R: RandomNumberGenerator>(to document: inout TimelineDocument,
        bumpers: [BumperAsset], options: WizardOptions, using generator: inout R) -> [String] {
        var used = Set(document.videoTrack.filter(\.bumper).compactMap(\.videoFile))
        var log: [String] = []
        func total() -> Double { document.videoTrack.map { $0.startTime + $0.duration }.max() ?? 0 }
        for (placement, enabled) in [(BumperPlacement.intro, options.includeIntroBumper),
                                     (.anywhere, options.includeMiddleBumper),
                                     (.outro, options.includeOutroBumper)] where enabled {
            let eligible = bumpers.filter {
                $0.placements.contains(placement) && ($0.duration ?? 0).isFinite && ($0.duration ?? 0) > 0
            }
            let unused = eligible.filter { !used.contains($0.path) }
            // A bumper the user named for this slot wins; a missing or
            // ineligible choice falls back to any eligible bumper.
            let chosenPath = placement == .intro ? options.introBumperPath
                : placement == .outro ? options.outroBumperPath : nil
            let chosen = chosenPath.flatMap { path in eligible.first { $0.path == path } }
            guard let bumper = chosen
                ?? (unused.isEmpty ? eligible : unused).randomElement(using: &generator) else { continue }
            let time: Double
            switch placement {
            case .intro: time = 0
            case .outro: time = total()
            case .anywhere:
                let end = total()
                let boundaries = Set(document.videoTrack.filter { !$0.bumper && $0.track == 0 }
                    .flatMap { [$0.startTime, $0.startTime + $0.duration] })
                    .filter { $0 >= end * 0.3 && $0 <= end * 0.7 }
                guard let boundary = boundaries.sorted().min(by: { abs($0 - end * 0.5) < abs($1 - end * 0.5) }) else { continue }
                time = boundary
            }
            guard let clip = bumper.clip(at: time) else { continue }
            insertGap(in: &document, at: time, duration: clip.duration)
            document.videoTrack.append(clip)
            document.videoTrack.sort { ($0.startTime, $0.track) < ($1.startTime, $1.track) }
            used.insert(bumper.path)
            log.append("Bumper '\(bumper.displayName)' inserted at \(String(format: "%.2f", time))s (\(placement.rawValue))")
        }
        return log
    }

    /// The inverse of ``insertGap``: close the stretch `time..<time+duration`
    /// on every lane. Items after it move earlier; items spanning it shrink;
    /// items entirely inside it collapse to the gap's start (video clips) or
    /// disappear (sound, overlays, crop blocks). Video pieces a previous
    /// insertion split stay two clips; sequential packing keeps them
    /// adjacent, which plays as one.
    static func removeGap(in document: inout TimelineDocument, at time: Double, duration: Double) {
        guard duration > 0 else { return }
        let gap = time..<(time + duration)
        func closed(_ start: Double, _ end: Double) -> (start: Double, end: Double)? {
            if end <= gap.lowerBound { return (start, end) }
            if start >= gap.upperBound { return (start - duration, end - duration) }
            let before = max(0, gap.lowerBound - start)
            let after = max(0, end - gap.upperBound)
            guard before + after > 0.001 else { return nil }
            let newStart = start < gap.lowerBound ? start : gap.lowerBound
            return (newStart, newStart + before + after)
        }
        for i in document.videoTrack.indices {
            let clip = document.videoTrack[i]
            if clip.startTime >= gap.upperBound {
                document.videoTrack[i].startTime -= duration
            } else if clip.startTime >= gap.lowerBound {
                document.videoTrack[i].startTime = gap.lowerBound
            }
        }
        // Dubbed speech moves back with its footage.
        if var lines = document.dubLines {
            for i in lines.indices where lines[i].start >= gap.upperBound { lines[i].start -= duration }
            document.dubLines = lines
        }
        document.soundTrack = document.soundTrack.compactMap { item in
            guard let range = closed(item.startTime, item.startTime + item.duration) else { return nil }
            var item = item
            item.startTime = range.start
            item.duration = range.end - range.start
            return item
        }
        document.textOverlays = document.textOverlays.compactMap { item in
            guard let range = closed(item.startTime, item.endTime) else { return nil }
            var item = item
            item.startTime = range.start
            item.endTime = range.end
            return item
        }
        document.imageOverlays = document.imageOverlays.compactMap { item in
            guard let range = closed(item.startTime, item.endTime) else { return nil }
            var item = item
            item.startTime = range.start
            item.endTime = range.end
            return item
        }
        document.overlayBlocks = document.overlayBlocks.compactMap { item in
            guard let range = closed(item.startTime, item.endTime) else { return nil }
            var item = item
            item.startTime = range.start
            item.duration = range.end - range.start
            return item
        }
        document.cropBlocks = document.cropBlocks.compactMap { block in
            guard let range = closed(block.startTime, block.endTime) else { return nil }
            var block = block
            block.startTime = range.start
            block.duration = range.end - range.start
            return block
        }
        if !document.cropBlocks.isEmpty { document.normalizeCropBlocks() }
    }

    /// Split crossing video/crop items and shift every lane. A sound already
    /// playing continues across the insertion; later sound starts move with
    /// their footage. Overlays keep their window and are suppressed by the
    /// compositor during the inserted bumper.
    static func insertGap(in document: inout TimelineDocument, at time: Double, duration: Double) {
        var clips: [TimelineClip] = []
        var tails: [UUID: UUID] = [:]
        for var clip in document.videoTrack {
            if clip.startTime >= time {
                clip.startTime += duration
            } else if clip.startTime + clip.duration > time {
                var tail = clip
                tail.uid = UUID()
                let consumed = time - clip.startTime
                tail.sourceStart = (clip.sourceStart ?? 0) + consumed * clip.effectiveSpeed
                tail.startTime = time + duration
                tail.duration -= consumed
                tail.transIn = nil
                // The camera path runs from the clip's source start: the tail
                // continues it from the split instead of replaying it.
                if let path = clip.cameraPath {
                    let sliced = CenterStageService.slice(path, from: consumed * clip.effectiveSpeed,
                                                          duration: tail.duration * clip.effectiveSpeed)
                    tail.cameraPath = sliced.count >= 2 ? sliced : nil
                }
                tails[clip.uid] = tail.uid
                // One dissolve, not two: the head keeps the way in, the
                // tail keeps the way out.
                tail.fadeIn = 0
                clip.fadeOut = 0
                clip.duration = consumed
                clip.sourceEnd = (clip.sourceStart ?? 0) + clip.sourceSpan
                clip.transOut = nil
                clips.append(tail)
            }
            clips.append(clip)
        }
        document.videoTrack = clips
        // Dubbed speech after the insertion moves with its footage (and the
        // split clip's tail owns it); a line already playing continues.
        if var lines = document.dubLines {
            for i in lines.indices where lines[i].start >= time {
                lines[i].start += duration
                if let tail = tails[lines[i].clipUID] { lines[i].clipUID = tail }
            }
            document.dubLines = lines
        }
        for i in document.soundTrack.indices {
            if document.soundTrack[i].startTime >= time { document.soundTrack[i].startTime += duration }
            else if document.soundTrack[i].startTime + document.soundTrack[i].duration > time {
                document.soundTrack[i].duration += duration
            }
        }
        for i in document.textOverlays.indices {
            if document.textOverlays[i].endTime > time { document.textOverlays[i].endTime += duration }
            if document.textOverlays[i].startTime >= time { document.textOverlays[i].startTime += duration }
        }
        for i in document.imageOverlays.indices {
            if document.imageOverlays[i].endTime > time { document.imageOverlays[i].endTime += duration }
            if document.imageOverlays[i].startTime >= time { document.imageOverlays[i].startTime += duration }
        }
        for i in document.overlayBlocks.indices {
            if document.overlayBlocks[i].startTime >= time { document.overlayBlocks[i].startTime += duration }
            else if document.overlayBlocks[i].endTime > time { document.overlayBlocks[i].duration += duration }
        }
        var blocks: [CropBlockItem] = []
        var spannedByLayout = false
        for var block in document.cropBlocks {
            if block.startTime >= time { block.startTime += duration }
            else if block.endTime > time {
                // Splitting would leave a piece the row normalizer drops
                // (under 0.5 s), and that piece could never be restored when
                // the gap closes. Stretch the block across the gap instead;
                // the bumper covers the row there anyway.
                if time - block.startTime < 0.5 || block.endTime - time < 0.5 {
                    block.duration += duration
                    spannedByLayout = true
                } else {
                    blocks.append(CropBlockItem(layout: block.layout, startTime: time + duration,
                                               duration: block.endTime - time))
                    block.duration = time - block.startTime
                }
            }
            blocks.append(block)
        }
        if !blocks.isEmpty {
            if !spannedByLayout {
                blocks.append(CropBlockItem(layout: .fullScreen, startTime: time, duration: duration))
            }
            document.cropBlocks = blocks.sorted { $0.startTime < $1.startTime }
        }
    }
}
