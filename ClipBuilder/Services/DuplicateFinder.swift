import Foundation

/// Cross-video duplicate detection: the same footage imported twice — a
/// re-download at a different resolution, a re-crop, a longer cut of the
/// same fight — grouped with a keep recommendation. Report-only: nothing is
/// deleted, the report just says which copy is the better source.
nonisolated enum DuplicateFinder {

    struct Group: Identifiable, Sendable, Hashable {
        var videoIDs: [Int64]
        var keepID: Int64
        var reason: String

        var id: Int64 { keepID }
    }

    /// Library cap per scan — one mid-video frame rides along per video.
    static let maxVideos = 30

    /// Collapse overlapping groups by video id; earlier groups keep their recommendation.
    static func merge(_ groups: [Group]) -> [Group] {
        var result: [Group] = []
        for group in groups {
            var ids = Set(group.videoIDs)
            var keep = group.keepID
            var reason = group.reason
            var hasEarlierKeep = false
            var changed = true
            while changed {
                changed = false
                if let index = result.firstIndex(where: { !ids.isDisjoint(with: $0.videoIDs) }) {
                    let earlier = result.remove(at: index)
                    ids.formUnion(earlier.videoIDs)
                    if !hasEarlierKeep {
                        keep = earlier.keepID
                        reason = earlier.reason
                        hasEarlierKeep = true
                    }
                    changed = true
                }
            }
            guard ids.count >= 2 else { continue }
            result.append(Group(videoIDs: ids.sorted(), keepID: ids.contains(keep) ? keep : ids.min()!, reason: reason))
        }
        return result
    }

    static func prompt(inventory: String) -> String {
        """
        You are checking a video library for DUPLICATE IMPORTS — videos that contain the SAME underlying footage (the same fight, the same recording) brought in more than once: a re-download at a different resolution, a cropped variant, a shorter or longer cut of the same material.

        Each video below has a metadata line and one mid-video frame labeled with its id.

        ## VIDEOS
        \(inventory)

        Rules:
        - Two videos are duplicates ONLY when the frames and metadata show the same underlying footage. The same people appearing in two DIFFERENT recordings (a fight and its recap, two training days) are NOT duplicates.
        - For each duplicate group, recommend keeping the best source: highest resolution first, then the more complete (longer) cut.

        Return ONLY a JSON object — an empty groups list when nothing is duplicated:
        {"groups": [{"video_ids": [<id>, <id>], "keep": <id of the copy to keep>, "reason": "<at most 15 words>"}]}
        """
    }

    static func parse(_ response: String, validIDs: Set<Int64>) -> [Group] {
        guard let object = AIResponseParser.jsonObject(from: response),
              let raw = object["groups"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            let ids = (entry["video_ids"] as? [Any] ?? [])
                .compactMap { ($0 as? NSNumber)?.int64Value }
                .filter(validIDs.contains)
            guard ids.count >= 2 else { return nil }
            let keep = (entry["keep"] as? NSNumber)?.int64Value
            return Group(videoIDs: ids,
                         keepID: keep.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0],
                         reason: (entry["reason"] as? String)?
                             .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
    }
}
