import CryptoKit
import Foundation

/// Portable inputs only. Arrays representing sets are canonicalized before encoding;
/// routing chains and trim endpoints retain their meaningful order.
nonisolated struct AnalysisRequest: Codable, Sendable, Equatable {
    var version = 1
    var sourceIdentity: String
    var videoType: String?
    var pipeline: Int
    var passVersions: [String: Int]
    var plan: AnalysisCheckpoint.Plan
    var notes: [AnalysisRunNote] = []
    var markers: [Marker] = []
    var people: [Person] = []
    var tags: [String: [String]] = [:]
    var domain = ""
    var tasteRubric = ""
    var taste: [Taste] = []
    var exemplarHashes: [String] = []
    var routing: [String: [Route]] = [:]
    var onDevice: [String: Bool] = [:]
    var transcriptKey: String?
    var transcriptHash: String?
    var language = ""
    var podcastJSON = "{}"
    var requestedPasses: [String] = []

    struct Marker: Codable, Sendable, Equatable {
        var at: Double
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var personKey: String?
        var ignored: Bool
    }
    struct Person: Codable, Sendable, Equatable {
        var key: String
        var descriptor: String
    }
    struct Taste: Codable, Sendable, Equatable {
        var key: String
        var rubric: String
        var exemplarHashes: [String]
    }
    struct Route: Codable, Sendable, Equatable {
        var provider: String
        var model: String?
    }

    func resolvedPeople(current: [PersonRecord]) -> [PersonRecord] {
        people.enumerated().map { index, saved in
            var person = current.first { $0.key == saved.key }
                ?? PersonRecord(id: -Int64(index + 1), key: saved.key, name: "", descriptor: saved.descriptor)
            person.descriptor = saved.descriptor
            return person
        }
    }

    func resolvedMarkers(videoID: Int64, people: [PersonRecord]) -> [PersonMarker] {
        markers.enumerated().map { index, marker in
            PersonMarker(id: Int64(index), videoID: videoID, atTime: marker.at, x: marker.x, y: marker.y,
                width: marker.width, height: marker.height,
                personID: people.first { $0.key == marker.personKey }?.id, ignored: marker.ignored)
        }
    }

    /// Passes and their versions follow the plan and the video type.
    mutating func refreshPasses() {
        let type = videoType.flatMap(VideoType.init(rawValue:))
        pipeline = AnalysisPipeline.current(for: type)
        requestedPasses = ["scenes"]
        if plan.detectPeople || type?.usesPodcastPass == true { requestedPasses.append("people") }
        if plan.includeTranscript || type?.usesPodcastPass == true { requestedPasses.append("transcript") }
        if type?.usesPodcastPass == true { requestedPasses.append("exchanges") }
        if plan.includeFightScoring && type?.supportsFightFeatures == true { requestedPasses.append("fightScore") }
        passVersions = Dictionary(uniqueKeysWithValues: requestedPasses.map { pass in
            let version: Int
            switch pass {
            case "people": version = AnalysisPipeline.peoplePass
            case "transcript": version = AnalysisPipeline.transcriptPass
            case "exchanges": version = AnalysisPipeline.exchangesPass
            case "fightScore": version = AnalysisPipeline.fightScorePass
            default: version = pipeline
            }
            return (pass, version)
        })
    }

    /// A run captured before the type was known infers it. Saving the request
    /// with that type lets an identical re-run, now captured with the known
    /// type, match the run instead of analyzing again. A known type is kept.
    func resolvingVideoType(_ type: VideoType) -> Self {
        guard videoType == nil else { return self }
        var value = self
        value.videoType = type.rawValue
        if type.usesPodcastPass { value.language = "" }
        value.refreshPasses()
        return value.normalized
    }

    var normalized: Self {
        var value = self
        value.plan.requiredPeopleKeys = Array(Set(plan.requiredPeopleKeys)).sorted()
        value.plan.breakdownTags = Array(Set(plan.breakdownTags)).sorted()
        // nil and zero both mean automatic. Keep that policy distinct from a
        // fixed interval: automatic also imposes a different frame budget.
        if (value.plan.sampleInterval ?? 0) <= 0 { value.plan.sampleInterval = nil }
        value.plan.pastedNotes = nil // captured explicitly, whether pasted or stored
        value.plan.provider = nil // effective routing below replaces UI overrides
        value.plan.model = nil
        value.notes = notes.sorted { $0.at == $1.at ? $0.note < $1.note : $0.at < $1.at }
        value.markers = markers.sorted { Self.json($0) < Self.json($1) }
        value.people = people.sorted { $0.key == $1.key ? $0.descriptor < $1.descriptor : $0.key < $1.key }
        value.tags = tags.mapValues { Array(Set($0)).sorted() }
        value.taste = taste.map { item in
            var item = item
            item.exemplarHashes = Array(Set(item.exemplarHashes)).sorted()
            return item
        }.sorted { $0.key < $1.key }
        value.exemplarHashes = Array(Set(exemplarHashes)).sorted()
        if let podcast = AISettingsJSON.decode(PodcastSettings.self, podcastJSON) { value.podcastJSON = Self.json(podcast) }
        value.requestedPasses = Array(Set(requestedPasses)).sorted()
        return value
    }

    var json: String { Self.json(normalized) }
    var fingerprint: String { Self.digest(Data(json.utf8)) }

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Inputs are finite media/settings values. Should encoding ever fail
        // (a non-finite number), the result must not crash the app and must
        // never make two unencodable requests look equal: a unique marker
        // guarantees the fingerprint matches nothing.
        if let data = try? encoder.encode(value) { return String(decoding: data, as: UTF8.self) }
        return "{\"unencodable\":\"\(UUID().uuidString)\"}"
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func transcriptFingerprint(_ rows: [TranscriptRow]) -> String? {
        guard !rows.isEmpty else { return nil }
        struct Input: Encodable {
            var start: Double
            var end: Double
            var text: String
            var language: String
            var speaker: String?
            var words: [TranscriptWord]?
        }
        let inputs = rows.map {
            Input(start: $0.startTime, end: $0.endTime, text: $0.text, language: $0.language,
                  speaker: $0.speakerKey, words: $0.words)
        }.sorted { $0.start == $1.start ? Self.json($0) < Self.json($1) : $0.start < $1.start }
        return digest(Data(json(inputs).utf8))
    }

    static func capturePlan(defaults: UserDefaults, singleVideo: Bool,
                            provider: String?, model: String?, includeFightScoring: Bool) -> AnalysisCheckpoint.Plan {
        let start = defaults.object(forKey: "analysis.trimStart") as? Double
        let end = defaults.object(forKey: "analysis.trimEnd") as? Double
        let trim: [Double]? = singleVideo && start != nil && end != nil && end! > start! ? [start!, end!] : nil
        let interval = defaults.double(forKey: "analysis.sampleInterval")
        return AnalysisCheckpoint.Plan(
            instructions: defaults.string(forKey: "analysis.instructions") ?? "",
            sampleInterval: interval > 0 ? interval : nil,
            detectPeople: defaults.object(forKey: "analysis.detectPeople") as? Bool ?? true,
            autoZoomUnframed: defaults.bool(forKey: "analysis.autoZoomUnframed"),
            breakdownTags: defaults.bool(forKey: "analysis.autoBreakdown")
                ? (defaults.string(forKey: "analysis.breakdownTags") ?? "").split(separator: ",").map(String.init) : [],
            trimRange: trim,
            requiredPeopleKeys: (defaults.string(forKey: "analysis.requiredPeople") ?? "").split(separator: ",").map(String.init),
            pastedNotes: AISettingsJSON.decode([AnalysisRunNote].self, defaults.string(forKey: "analysis.pastedNotes")),
            smartSampling: defaults.object(forKey: "analysis.smartSampling") as? Bool ?? true,
            includeTranscript: defaults.bool(forKey: "analysis.includeTranscript"), includeFightScoring: includeFightScoring,
            provider: provider, model: model)
    }

    static func consumeOneShotDefaults(_ defaults: UserDefaults) {
        for key in ["trimStart", "trimEnd", "requiredPeople", "pastedNotes"] {
            defaults.removeObject(forKey: "analysis.\(key)")
        }
    }

    func restorePlan(to defaults: UserDefaults) {
        defaults.set(plan.instructions, forKey: "analysis.instructions")
        defaults.set(plan.sampleInterval ?? 0, forKey: "analysis.sampleInterval")
        defaults.set(plan.detectPeople, forKey: "analysis.detectPeople")
        defaults.set(plan.autoZoomUnframed, forKey: "analysis.autoZoomUnframed")
        defaults.set(!plan.breakdownTags.isEmpty, forKey: "analysis.autoBreakdown")
        defaults.set(plan.breakdownTags.joined(separator: ","), forKey: "analysis.breakdownTags")
        defaults.set(plan.trimRange?.first, forKey: "analysis.trimStart")
        defaults.set(plan.trimRange?.last, forKey: "analysis.trimEnd")
        defaults.set(plan.requiredPeopleKeys.joined(separator: ","), forKey: "analysis.requiredPeople")
        defaults.set(Self.json(notes), forKey: "analysis.pastedNotes")
        defaults.set(plan.smartSampling, forKey: "analysis.smartSampling")
        defaults.set(plan.includeTranscript, forKey: "analysis.includeTranscript")
    }
}

/// Inherited by actor calls, including saveAnalysis and AI dispatch; never global
/// mutable settings. Each video's operation gets its own frozen request.
nonisolated enum AnalysisRequestContext {
    @TaskLocal static var current: AnalysisRequest?
}
