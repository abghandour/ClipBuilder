import Foundation

nonisolated struct ProjectUIState: Codable, Sendable, Equatable {
    var section = "sources"
    var openTimelineID: Int64?
    var playhead = 0.0
    var zoom = 60.0
    var sceneFilter = "all"
    var outputsSort = "newest"
    var outputsScrollID: Int64?

    var sourceSelection: Set<Int64> = []
    var sourceScrollID: Int64?
    var sceneSelection: Set<Int64> = []
    var sceneScrollID: Int64?
    var sceneRunSelection: Set<Int64> = []
    var sceneTagFilter: String?
    var sceneSearchText = ""
    var sceneShowHidden = false
    var sceneSortByScore = false
    var sceneMinimumScore = 0.0
    var sceneShowSequenceParts = false
    var timelineSelection: TimelineSelection?
    var timelineFocusedTrack: Int?
    var timelineScrollX = 0.0
    var timelineScrollY = 0.0

    init(
        section: String = "sources",
        openTimelineID: Int64? = nil,
        playhead: Double = 0,
        zoom: Double = 60,
        sceneFilter: String = "all",
        outputsSort: String = "newest",
        outputsScrollID: Int64? = nil,
        sourceSelection: Set<Int64> = [],
        sourceScrollID: Int64? = nil,
        sceneSelection: Set<Int64> = [],
        sceneScrollID: Int64? = nil,
        sceneRunSelection: Set<Int64> = [],
        sceneTagFilter: String? = nil,
        sceneSearchText: String = "",
        sceneShowHidden: Bool = false,
        sceneSortByScore: Bool = false,
        sceneMinimumScore: Double = 0,
        sceneShowSequenceParts: Bool = false,
        timelineSelection: TimelineSelection? = nil,
        timelineFocusedTrack: Int? = nil,
        timelineScrollX: Double = 0,
        timelineScrollY: Double = 0
    ) {
        self.section = section
        self.openTimelineID = openTimelineID
        self.playhead = playhead
        self.zoom = zoom
        self.sceneFilter = sceneFilter
        self.outputsSort = outputsSort
        self.outputsScrollID = outputsScrollID
        self.sourceSelection = sourceSelection
        self.sourceScrollID = sourceScrollID
        self.sceneSelection = sceneSelection
        self.sceneScrollID = sceneScrollID
        self.sceneRunSelection = sceneRunSelection
        self.sceneTagFilter = sceneTagFilter
        self.sceneSearchText = sceneSearchText
        self.sceneShowHidden = sceneShowHidden
        self.sceneSortByScore = sceneSortByScore
        self.sceneMinimumScore = sceneMinimumScore
        self.sceneShowSequenceParts = sceneShowSequenceParts
        self.timelineSelection = timelineSelection
        self.timelineFocusedTrack = timelineFocusedTrack
        self.timelineScrollX = timelineScrollX
        self.timelineScrollY = timelineScrollY
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        section = try values.decodeIfPresent(String.self, forKey: .section) ?? "sources"
        openTimelineID = try values.decodeIfPresent(Int64.self, forKey: .openTimelineID)
        playhead = try values.decodeIfPresent(Double.self, forKey: .playhead) ?? 0
        zoom = try values.decodeIfPresent(Double.self, forKey: .zoom) ?? 60
        sceneFilter = try values.decodeIfPresent(String.self, forKey: .sceneFilter) ?? "all"
        outputsSort = try values.decodeIfPresent(String.self, forKey: .outputsSort) ?? "newest"
        outputsScrollID = try values.decodeIfPresent(Int64.self, forKey: .outputsScrollID)
        sourceSelection = try values.decodeIfPresent(Set<Int64>.self, forKey: .sourceSelection) ?? []
        sourceScrollID = try values.decodeIfPresent(Int64.self, forKey: .sourceScrollID)
        sceneSelection = try values.decodeIfPresent(Set<Int64>.self, forKey: .sceneSelection) ?? []
        sceneScrollID = try values.decodeIfPresent(Int64.self, forKey: .sceneScrollID)
        sceneRunSelection = try values.decodeIfPresent(Set<Int64>.self, forKey: .sceneRunSelection) ?? []
        sceneTagFilter = try values.decodeIfPresent(String.self, forKey: .sceneTagFilter)
        sceneSearchText = try values.decodeIfPresent(String.self, forKey: .sceneSearchText) ?? ""
        sceneShowHidden = try values.decodeIfPresent(Bool.self, forKey: .sceneShowHidden) ?? false
        sceneSortByScore =
            try values.decodeIfPresent(Bool.self, forKey: .sceneSortByScore)
            ?? ((try values.decodeIfPresent(String.self, forKey: .sceneSort)) == "score")
        sceneMinimumScore = try values.decodeIfPresent(Double.self, forKey: .sceneMinimumScore) ?? 0
        sceneShowSequenceParts = try values.decodeIfPresent(Bool.self, forKey: .sceneShowSequenceParts) ?? false
        timelineSelection = try values.decodeIfPresent(TimelineSelection.self, forKey: .timelineSelection)
        timelineFocusedTrack = try values.decodeIfPresent(Int.self, forKey: .timelineFocusedTrack)
        timelineScrollX = try values.decodeIfPresent(Double.self, forKey: .timelineScrollX) ?? 0
        timelineScrollY = try values.decodeIfPresent(Double.self, forKey: .timelineScrollY) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(section, forKey: .section)
        try values.encodeIfPresent(openTimelineID, forKey: .openTimelineID)
        try values.encode(playhead, forKey: .playhead)
        try values.encode(zoom, forKey: .zoom)
        try values.encode(sceneFilter, forKey: .sceneFilter)
        try values.encode(outputsSort, forKey: .outputsSort)
        try values.encodeIfPresent(outputsScrollID, forKey: .outputsScrollID)
        try values.encode(sourceSelection, forKey: .sourceSelection)
        try values.encodeIfPresent(sourceScrollID, forKey: .sourceScrollID)
        try values.encode(sceneSelection, forKey: .sceneSelection)
        try values.encodeIfPresent(sceneScrollID, forKey: .sceneScrollID)
        try values.encode(sceneRunSelection, forKey: .sceneRunSelection)
        try values.encodeIfPresent(sceneTagFilter, forKey: .sceneTagFilter)
        try values.encode(sceneSearchText, forKey: .sceneSearchText)
        try values.encode(sceneShowHidden, forKey: .sceneShowHidden)
        try values.encode(sceneSortByScore, forKey: .sceneSortByScore)
        try values.encode(sceneMinimumScore, forKey: .sceneMinimumScore)
        try values.encode(sceneShowSequenceParts, forKey: .sceneShowSequenceParts)
        try values.encodeIfPresent(timelineSelection, forKey: .timelineSelection)
        try values.encodeIfPresent(timelineFocusedTrack, forKey: .timelineFocusedTrack)
        try values.encode(timelineScrollX, forKey: .timelineScrollX)
        try values.encode(timelineScrollY, forKey: .timelineScrollY)
    }

    private enum CodingKeys: String, CodingKey {
        case section, openTimelineID, playhead, zoom, sceneFilter, sceneSort, outputsSort, outputsScrollID
        case sourceSelection, sourceScrollID, sceneSelection, sceneScrollID, sceneRunSelection
        case sceneTagFilter, sceneSearchText, sceneShowHidden, sceneSortByScore, sceneMinimumScore
        case sceneShowSequenceParts, timelineSelection, timelineFocusedTrack, timelineScrollX, timelineScrollY
    }
}
