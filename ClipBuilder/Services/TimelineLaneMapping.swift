import Foundation

/// One traversal of the non-video lanes, with the original pause arithmetic.
nonisolated enum TimelineLaneMapping {
    case pause(time: Double, delta: Double)
    case stretches([StrikeImpactRules.Stretch])

    func point(_ value: Double) -> Double {
        switch self {
        case .pause(let time, let delta):
            return Self.start(value, at: time, by: delta)
        case .stretches(let stretches):
            return StrikeImpactRules.mapped(value, through: stretches)
        }
    }

    func span(_ start: Double, _ end: Double) -> (start: Double, end: Double)? {
        if case .pause(let time, let delta) = self, delta > 0 {
            return (point(start), end > time ? end + delta : end)
        }
        let newStart = point(start), newEnd = point(end)
        return newEnd > newStart ? (newStart, newEnd) : nil
    }

    func local(to origin: Double) -> Self {
        switch self {
        case .pause(let time, let delta): return .pause(time: time - origin, delta: delta)
        case .stretches(let stretches):
            return .stretches(stretches.map {
                .init(start: $0.start - origin, end: $0.end - origin, factor: $0.factor)
            })
        }
    }

    func imageKeys(_ keys: [ImageTrackKey]) -> [ImageTrackKey] {
        switch self {
        case .pause(let time, let delta): return Self.keys(keys, at: time, by: delta)
        case .stretches(let stretches):
            var samples = keys
            if let first = keys.first, let last = keys.last {
                for time in Set(stretches.flatMap { [$0.start, $0.end] }).sorted() {
                    guard time > first.time, time < last.time,
                          !samples.contains(where: { abs($0.time - time) < 1e-9 }),
                          var key = ImageTrackKey.interpolate(keys, at: time) else { continue }
                    key.time = time
                    samples.append(key)
                }
            }
            return samples.sorted { $0.time < $1.time }.map {
                var key = $0
                key.time = point(key.time)
                return key
            }
        }
    }

    func apply(to document: inout TimelineDocument) {
        if case .pause(_, let delta) = self, delta == 0 { return }
        // Voice stays at normal speed; only its stored timeline placement moves.
        if var lines = document.dubLines {
            for index in lines.indices { lines[index].start = point(lines[index].start) }
            document.dubLines = lines
        }
        document.soundTrack = document.soundTrack.compactMap { item in
            guard let range = span(item.startTime, item.startTime + item.duration) else { return nil }
            var item = item
            item.startTime = range.start
            item.duration = range.end - range.start
            return item
        }
        document.textOverlays = texts(document.textOverlays)
        document.imageOverlays = images(document.imageOverlays)
        document.overlayBlocks = document.overlayBlocks.compactMap { item in
            guard let range = span(item.startTime, item.endTime) else { return nil }
            var item = item
            switch self {
            case .pause(let time, _) where !(item.startTime < time && item.endTime > time): break
            default:
                let mapping = local(to: item.startTime)
                item.composition.texts = mapping.texts(item.composition.texts, bounded: true)
                item.composition.images = mapping.images(item.composition.images, bounded: true)
                if case .stretches = self {
                    // Local clocks count from the newly mapped block origin.
                    let offset = mapping.point(0)
                    for i in item.composition.texts.indices {
                        item.composition.texts[i].startTime -= offset
                        item.composition.texts[i].endTime -= offset
                    }
                    for i in item.composition.images.indices {
                        item.composition.images[i].startTime -= offset
                        item.composition.images[i].endTime -= offset
                        item.composition.images[i].track = item.composition.images[i].track?.map {
                            var key = $0; key.time -= offset; return key
                        }
                    }
                }
            }
            item.startTime = range.start
            item.duration = range.end - range.start
            return item
        }
        document.cropBlocks = document.cropBlocks.compactMap { item in
            if case .pause(let time, let delta) = self, delta > 0, abs(item.startTime - time) < 1e-9 {
                var item = item
                item.duration += delta
                return item
            }
            guard let range = span(item.startTime, item.endTime) else { return nil }
            var item = item
            item.startTime = range.start
            item.duration = range.end - range.start
            return item
        }
    }

    private func texts(_ items: [TextOverlayItem], bounded: Bool = false) -> [TextOverlayItem] {
        items.compactMap { item in
            if bounded, item.unbounded {
                var item = item
                let moved = point(item.startTime) - item.startTime
                item.startTime += moved
                item.endTime += moved
                return item
            }
            guard let range = span(item.startTime, item.endTime) else { return nil }
            var item = item
            item.startTime = range.start
            item.endTime = range.end
            return item
        }
    }

    private func images(_ items: [ImageOverlayItem], bounded: Bool = false) -> [ImageOverlayItem] {
        items.compactMap { item in
            var item = item
            if let path = item.track { item.track = imageKeys(path) }
            if bounded, item.unbounded {
                let moved = point(item.startTime) - item.startTime
                item.startTime += moved
                item.endTime += moved
                return item
            }
            guard let range = span(item.startTime, item.endTime) else { return nil }
            item.startTime = range.start
            item.endTime = range.end
            return item
        }
    }

    private static func start(_ value: Double, at time: Double, by delta: Double) -> Double {
        guard value >= time else { return value }
        return delta > 0 ? value + delta : max(time, value + delta)
    }

    /// A tracked image stands still through the pause: the path gets a key
    /// where the pause begins and the same key where it ends.
    private static func keys(_ keys: [ImageTrackKey], at time: Double, by delta: Double) -> [ImageTrackKey] {
        var result = keys
        if delta > 0 {
            let earlier = keys.filter { $0.time < time - 1e-9 }, later = keys.filter { $0.time > time + 1e-9 }
            // The place the image has when the pause begins: a key set there,
            // or the point on the way between its neighbours.
            var stop = keys.first { abs($0.time - time) <= 1e-9 }
            if stop == nil, let before = earlier.last, let after = later.first {
                let part = (time - before.time) / (after.time - before.time)
                var between = before
                between.xFrac += (after.xFrac - before.xFrac) * part
                between.yFrac += (after.yFrac - before.yFrac) * part
                between.wFrac += (after.wFrac - before.wFrac) * part
                stop = between
            }
            // A pause before the first key has no interpolated stop, but
            // every later key must still follow the overlay's timeline clock.
            guard var stop else {
                return keys.map { key in
                    var key = key
                    key.time = start(key.time, at: time, by: delta)
                    return key
                }
            }
            stop.time = time
            var resume = stop
            resume.time = time + delta
            return earlier + [stop, resume] + later.map { key in var key = key; key.time += delta; return key }
        }
        for index in result.indices { result[index].time = start(result[index].time, at: time, by: delta) }
        // Closing a pause brings its two standing keys together: keep one.
        var seen: [ImageTrackKey] = []
        for key in result {
            if let last = seen.last, abs(last.time - key.time) < 1e-9 { seen[seen.count - 1] = key } else { seen.append(key) }
        }
        return seen
    }

}
