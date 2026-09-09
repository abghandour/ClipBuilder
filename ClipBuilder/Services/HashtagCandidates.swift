import Foundation

nonisolated enum HashtagCandidates {
    static func make(pins: [String], tags: [String], people: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        return Array((pins + tags + people).compactMap { value -> String? in
            let parts = value.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            let name = parts.count == 1 ? parts[0] : parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            return "#" + name
        }.prefix(max(0, limit)))
    }
}
