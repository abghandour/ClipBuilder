import Foundation
import Synchronization

nonisolated struct OutputFolder: Identifiable, Equatable {
    enum Section: String, CaseIterable {
        case smart = "Smart", date = "By Date", source = "By Source", batch = "By Batch"

        var symbol: String {
            switch self {
            case .smart: "sparkles.rectangle.stack"
            case .date: "calendar"
            case .source: "film"
            case .batch: "square.stack.3d.up"
            }
        }
    }
    var id: String
    var title: String
    var section: Section
    var videoIDs: Set<Int64>
    var count: Int { videoIDs.count }
    var symbol: String {
        switch id {
        case "all": "film.stack"
        case "today": "calendar"
        case "favorites": "heart"
        default: "folder"
        }
    }
}

nonisolated enum OutputFolders {
    /// Cache only timeline-derived values. Legacy scene references must still
    /// resolve against each build's scene paths, and settings remain live.
    struct TimelineSources: Sendable {
        var names: Set<String>
        var sceneIDs: Set<Int64>
        var format: String?

        func sourceNames(scenePaths: [Int64: String]) -> Set<String> {
            names.union(sceneIDs.compactMap { scenePaths[$0].flatMap(OutputFolders.filename) })
        }
    }

    nonisolated final class TimelineCache: Sendable {
        private struct Entry: Sendable {
            var jsonHash: Int
            var json: String
            var sources: TimelineSources
        }

        private let entries = Mutex<[Int64: Entry]>([:])

        fileprivate func sources(for record: GeneratedVideoRecord, decode: (String) -> Any?) -> TimelineSources {
            let hash = record.timelineJSON.hashValue
            return entries.withLock { entries in
                if let entry = entries[record.id], entry.jsonHash == hash, entry.json == record.timelineJSON {
                    return entry.sources
                }
                let sources = OutputFolders.timelineSources(in: decode(record.timelineJSON))
                // Keep only the current JSON per record and bound cross-profile
                // growth. Compare JSON too so a hash collision cannot misgroup.
                if entries.count >= 2_048 { entries.removeAll(keepingCapacity: true) }
                entries[record.id] = Entry(jsonHash: hash, json: record.timelineJSON, sources: sources)
                return sources
            }
        }
    }

    private static let timelineCache = TimelineCache()

    static func resolvedSelection(_ selection: String?, in folders: [OutputFolder]) -> String {
        guard let selection, folders.contains(where: { $0.id == selection }) else { return "all" }
        return selection
    }

    static func membership(for selection: String?, in folders: [OutputFolder]) -> Set<Int64> {
        folders.first { $0.id == (selection ?? "all") }?.videoIDs ?? []
    }

    static func build(records: [GeneratedVideoRecord], scenes: [SceneRecord], timelines: [TimelineRecord] = [],
                      now: Date = .now, calendar: Calendar = .current,
                      cache: TimelineCache = timelineCache,
                      decodeTimeline: (String) -> Any? = { try? JSONSerialization.jsonObject(with: Data($0.utf8)) },
                      decodeSettings: (String) -> WizardRunSettings? = { AISettingsJSON.decode(WizardRunSettings.self, $0) }) -> [OutputFolder] {
        let scenePaths = Dictionary(scenes.map { ($0.id, $0.videoPath) }, uniquingKeysWith: { first, _ in first })
        let dates = Dictionary(records.compactMap { record in
            AIProvenance.parseDate(record.generatedAt).map { (record.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        var result = [
            OutputFolder(id: "all", title: "All", section: .smart, videoIDs: Set(records.map(\.id))),
            OutputFolder(id: "today", title: "Today", section: .smart,
                         videoIDs: Set(records.filter { dates[$0.id].map { calendar.isDate($0, inSameDayAs: now) } ?? false }.map(\.id))),
            OutputFolder(id: "favorites", title: "Favorites", section: .smart, videoIDs: Set(records.filter(\.favorite).map(\.id)))
        ]
        let dateLabel = DateFormatter()
        dateLabel.calendar = calendar
        dateLabel.timeZone = calendar.timeZone
        dateLabel.dateStyle = .medium
        var days: [Date: Set<Int64>] = [:]
        var sources: [String: Set<Int64>] = [:]
        var batches: [String: [GeneratedVideoRecord]] = [:]
        var batchDates: [String: Date] = [:]
        var formats: [Int64: String] = [:]
        var unknownDates = Set<Int64>()
        for record in records {
            if let date = dates[record.id] { days[calendar.startOfDay(for: date), default: []].insert(record.id) }
            else { unknownDates.insert(record.id) }
            let timeline = cache.sources(for: record, decode: decodeTimeline)
            for source in timeline.sourceNames(scenePaths: scenePaths) {
                sources[source, default: []].insert(record.id)
            }
            if let batch = record.batchID, !batch.isEmpty {
                batches[batch, default: []].append(record)
                if let date = dates[record.id] { batchDates[batch] = min(batchDates[batch] ?? date, date) }
                formats[record.id] = formatName(record.settingsJSON.flatMap(decodeSettings)?.options.formatPreset
                    ?? timeline.format)
            }
        }
        for day in days.keys.sorted(by: >) {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            result.append(OutputFolder(id: "date:\(key)", title: dateLabel.string(from: day), section: .date, videoIDs: days[day]!))
        }
        if !unknownDates.isEmpty {
            result.append(OutputFolder(id: "date:unknown", title: "Unknown date", section: .date, videoIDs: unknownDates))
        }
        for name in sources.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            result.append(OutputFolder(id: "source:\(name)", title: name, section: .source, videoIDs: sources[name]!))
        }
        dateLabel.timeStyle = .short
        for key in batches.keys.sorted(by: {
            let lhs = batchDates[$0] ?? .distantPast, rhs = batchDates[$1] ?? .distantPast
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }) {
            let members = batches[key]!.sorted { $0.id < $1.id }
            // Stop as soon as one member supplies the batch label.
            let format = members.lazy.compactMap { formats[$0.id] }.first
                ?? timelines.first { $0.isWizard && $0.sourceRunID == key }?.name.replacingOccurrences(of: "Wizard · ", with: "")
                ?? "Wizard"
            let date = batchDates[key] ?? .distantPast
            let stamp = date == .distantPast ? "Unknown date" : dateLabel.string(from: date)
            result.append(OutputFolder(id: "batch:\(key)", title: "\(format) · \(stamp)", section: .batch, videoIDs: Set(members.map(\.id))))
        }
        return result
    }

    static func sourceNames(_ json: String, scenePaths: [Int64: String]) -> Set<String> {
        timelineSources(in: try? JSONSerialization.jsonObject(with: Data(json.utf8))).sourceNames(scenePaths: scenePaths)
    }

    private static func timelineSources(in timeline: Any?) -> TimelineSources {
        // Read only the fields needed for grouping, from modern or legacy JSON.
        let object = timeline as? [String: Any]
        let entries = object?["video_track"] as? [[String: Any]]
            ?? (timeline as? [[String: Any]])?.filter { $0["type"] as? String == "clip" } ?? []
        var names = Set<String>()
        var sceneIDs = Set<Int64>()
        for entry in entries {
            if let path = entry["video_file"] as? String {
                if let name = filename(path) { names.insert(name) }
            } else if let id = entry["id"] as? NSNumber {
                sceneIDs.insert(id.int64Value)
            }
        }
        return TimelineSources(names: names, sceneIDs: sceneIDs,
            format: object?["format_name"] as? String ?? object?["formatPreset"] as? String)
    }

    private static func filename(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func formatName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return ReelRecipe.all.first { $0.id == raw }?.title ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
