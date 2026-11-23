import Foundation

nonisolated enum BuilderDubLayout {
    struct Block: Identifiable, Sendable, Equatable {
        var line: DubLine
        var end: Double
        var row: Int
        var freezes: [Range<Double>]
        var prepared: Bool
        var id: UUID { line.id }
        var duration: Double { end - line.start }
    }

    struct Layout: Sendable, Equatable {
        var blocks: [Block]
        var rows: Int
        var isEmpty: Bool { blocks.isEmpty }
    }

    static func layout(document: TimelineDocument, missingAudio: Set<String> = []) -> Layout {
        let freezes = DubFreezes.intervals(in: document)
        var rowEnds = [-Double.infinity, -Double.infinity]
        let lines = (document.dubLines ?? []).sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
        let blocks = lines.map { line in
            let layout = DubPauseRules.layout(line, freezes: freezes)
            let row = rowEnds[0] <= line.start ? 0 : (rowEnds[1] <= line.start ? 1 : (rowEnds[0] <= rowEnds[1] ? 0 : 1))
            rowEnds[row] = layout.end
            let gaps = freezes.compactMap { freeze -> Range<Double>? in
                let lower = max(line.start, freeze.lowerBound), upper = min(layout.end, freeze.upperBound)
                return upper > lower ? lower..<upper : nil
            }
            let prepared = line.audio.map { !$0.isEmpty && $0 == URL(fileURLWithPath: $0).lastPathComponent && !missingAudio.contains($0) } ?? false
            return Block(line: line, end: layout.end, row: row, freezes: gaps, prepared: prepared)
        }
        return Layout(blocks: blocks, rows: blocks.isEmpty ? 0 : (blocks.map(\.row).max() ?? 0) + 1)
    }

    @concurrent
    static func missingAudio(lines: [DubLine], directory: URL = DubSynthesizer.cacheDirectory) async -> Set<String> {
        Set(lines.compactMap { line in
            guard let name = line.audio else { return nil }
            return !name.isEmpty && name == URL(fileURLWithPath: name).lastPathComponent
                && FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) ? nil : name
        })
    }
}
