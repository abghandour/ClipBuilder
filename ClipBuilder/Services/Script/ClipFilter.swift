import Foundation

nonisolated struct ScriptTimeRange: Codable, Sendable, Equatable {
    var start: Double
    var end: Double

    func validate() throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start else {
            throw ScriptError.invalid("A range needs finite, increasing nonnegative endpoints.")
        }
    }

    func overlaps(start: Double, end: Double) -> Bool {
        start < self.end && self.start < end
    }

    init(start: Double, end: Double) { self.start = start; self.end = end }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ScriptKey.self)
        try c.only(["start", "end"])
        start = try c.decode(Double.self, forKey: ScriptKey("start"))
        end = try c.decode(Double.self, forKey: ScriptKey("end"))
        try validate()
    }
}

/// Person matches use scene tags or overlapping video-roster evidence.
nonisolated struct ClipFilter: Codable, Sendable, Equatable {
    var track: Int? = nil
    var role: ClipRole? = nil
    var includeBumpers = false
    var people: [String] = []
    var tags: [String] = []
    var anyTags: [String] = []
    var between: ScriptTimeRange? = nil
    var sceneScoreBelow: Double? = nil

    enum CodingKeys: String, CodingKey {
        case track, role, people, tags, between
        case includeBumpers = "include_bumpers", anyTags = "any_tags", sceneScoreBelow = "scene_score_below"
    }

    init() {}
    init(from decoder: Decoder) throws {
        try decoder.container(keyedBy: ScriptKey.self).only([
            "track", "role", "include_bumpers", "people", "tags", "any_tags", "between", "scene_score_below"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        track = try c.decodeIfPresent(Int.self, forKey: .track)
        role = try c.decodeIfPresent(ClipRole.self, forKey: .role)
        includeBumpers = try c.decodeIfPresent(Bool.self, forKey: .includeBumpers) ?? false
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        anyTags = try c.decodeIfPresent([String].self, forKey: .anyTags) ?? []
        between = try c.decodeIfPresent(ScriptTimeRange.self, forKey: .between)
        sceneScoreBelow = try c.decodeIfPresent(Double.self, forKey: .sceneScoreBelow)
        try validate()
    }

    func validate() throws {
        try between?.validate()
        guard track.map({ (0..<TimelineDocument.maxTracks).contains($0) }) ?? true,
              sceneScoreBelow.map(\.isFinite) ?? true,
              people.count + tags.count + anyTags.count <= 100 else {
            throw ScriptError.invalid("Invalid clip filter or too many terms.")
        }
    }

    func matches(_ clip: TimelineClip, scene: SceneRecord?, library: ScriptLibrarySnapshot = .init()) -> Bool {
        guard includeBumpers || !clip.bumper,
              track == nil || track == clip.track, role == nil || role == clip.role,
              between?.overlaps(start: clip.startTime, end: clip.startTime + clip.duration) ?? true else { return false }
        let sceneTags = Set(scene?.tags ?? [])
        let roster = library.rosterPeople(for: clip, scene: scene)
        let scenePeople = Set(sceneTags.filter { $0.lowercased().hasPrefix("person:") }
            .map { String($0.dropFirst(7)).lowercased() })
        let matchesPeople = people.allSatisfy { requested in
            scenePeople.contains(requested.lowercased()) || roster.contains {
                $0.key.caseInsensitiveCompare(requested) == .orderedSame
                    || $0.name.caseInsensitiveCompare(requested) == .orderedSame
            }
        }
        guard Set(tags).isSubset(of: sceneTags),
              matchesPeople,
              anyTags.isEmpty || !sceneTags.isDisjoint(with: anyTags) else { return false }
        if let threshold = sceneScoreBelow {
            guard let score = scene?.score, score.isFinite, score < threshold else { return false }
        }
        return true
    }
}

nonisolated struct SceneFilter: Codable, Sendable, Equatable {
    var people: [String] = []
    var tags: [String] = []
    var video: Int64? = nil
    var text: String? = nil
    var minScore: Double? = nil
    var includeExcluded = false

    enum CodingKeys: String, CodingKey {
        case people, tags, video, text
        case minScore = "min_score", includeExcluded = "include_excluded"
    }
    init() {}
    init(from decoder: Decoder) throws {
        try decoder.container(keyedBy: ScriptKey.self).only([
            "people", "tags", "video", "text", "min_score", "include_excluded"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        video = try c.decodeIfPresent(Int64.self, forKey: .video)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        minScore = try c.decodeIfPresent(Double.self, forKey: .minScore)
        includeExcluded = try c.decodeIfPresent(Bool.self, forKey: .includeExcluded) ?? false
    }
    func matches(_ scene: SceneRecord) -> Bool {
        (includeExcluded || !scene.excluded) && (video == nil || video == scene.videoID)
            && Set(tags + people.map { "person:\($0)" }).isSubset(of: Set(scene.tags))
            && (text.map { (scene.narrative ?? "").localizedCaseInsensitiveContains($0)
                || scene.videoFilename.localizedCaseInsensitiveContains($0) } ?? true)
            && (minScore.map { threshold in scene.score.map { $0.isFinite && $0 >= threshold } ?? false } ?? true)
    }
}
