import Foundation

nonisolated enum TranscriptTextDiff {
    enum Kind: Equatable { case same, inserted, deleted }
    struct Token: Equatable {
        var kind: Kind
        var text: String
    }

    /// An exact, whitespace-token LCS. Deletions precede insertions on ties.
    static func diff(original: String, edited: String) -> [Token] {
        let old = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = edited.split(whereSeparator: \.isWhitespace).map(String.init)
        let width = new.count + 1
        var lengths = [Int](repeating: 0, count: (old.count + 1) * width)
        for i in old.indices.reversed() {
            for j in new.indices.reversed() {
                lengths[i * width + j] = old[i] == new[j]
                    ? 1 + lengths[(i + 1) * width + j + 1]
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var result: [Token] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] {
                result.append(.init(kind: .same, text: old[i]))
                i += 1
                j += 1
            } else if i < old.count && (j == new.count || lengths[(i + 1) * width + j] >= lengths[i * width + j + 1]) {
                result.append(.init(kind: .deleted, text: old[i]))
                i += 1
            } else {
                result.append(.init(kind: .inserted, text: new[j]))
                j += 1
            }
        }
        return result
    }
}
