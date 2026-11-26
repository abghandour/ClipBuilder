import CryptoKit
import Foundation

/// Remembers which transcript text has had its dub accepted in a review, so
/// Generate does not ask again for a dub the user already approved. A line is
/// vouched for by its source: language, video and the transcript's own words.
/// New or changed transcript text has no key yet, so it brings the review back;
/// removing text, or using less of it, does not.
nonisolated enum DubAcceptance {
    /// Nil for a line with no transcript behind it: nothing can vouch for it.
    static func key(_ line: DubLine) -> String? {
        guard let source = line.takeSource else { return nil }
        let text = DubTakeCutter.normalized(source.text)
        guard !text.isEmpty else { return nil }
        let data = Data("\(source.language)|\(source.videoID)|\(text)".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func keys(_ lines: [DubLine]) -> Set<String> { Set(lines.compactMap(key)) }

    /// True only when every line's text was in a dub the user accepted before.
    static func covers(_ lines: [DubLine], accepted: Set<String>) -> Bool {
        !lines.isEmpty && lines.allSatisfy { line in key(line).map(accepted.contains) ?? false }
    }

    /// Beside the profile's database, local to this Mac.
    static func file(database: URL) -> URL {
        database.deletingLastPathComponent().appendingPathComponent("dub_accepted.json")
    }

    static func load(_ file: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: file),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys)
    }

    /// Oldest keys are dropped first once the list is long.
    static let limit = 20_000

    static func remember(_ lines: [DubLine], file: URL) throws {
        let new = keys(lines)
        guard !new.isEmpty else { return }
        var stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let known = Set(stored)
        stored += new.subtracting(known).sorted()
        if stored.count > limit { stored.removeFirst(stored.count - limit) }
        try JSONEncoder().encode(stored).write(to: file, options: .atomic)
    }
}
