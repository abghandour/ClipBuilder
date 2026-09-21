import Foundation
import Testing
@testable import Clip_Builder

@Suite("Output folders")
struct OutputFolderTests {
    @Test func countsDatesSourcesFavoritesAndBatches() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var first = Fixtures.generatedVideo(id: 1, batchID: "run-a")
        first.generatedAt = "2026-09-20 12:30:00"
        first.favorite = true
        var options = WizardOptions()
        options.formatPreset = "podcast_highlights"
        first.settingsJSON = AISettingsJSON.encode(WizardRunSettings(options: options))
        first.timelineJSON = #"{"video_track":[{"video_file":"/source/Podcast.mp4","start":0,"end":5},{"id":7},{"video_file":"/source/Podcast.mp4"}]}"#
        var second = Fixtures.generatedVideo(id: 2, batchID: "run-a")
        second.generatedAt = "2026-09-20 13:00:00"
        second.timelineJSON = #"[{"type":"clip","video_file":"/source/Podcast.mp4","start":0,"end":5}]"#
        var third = Fixtures.generatedVideo(id: 3, batchID: "run-b")
        third.generatedAt = "2026-09-19 12:00:00"
        third.timelineJSON = "not json"
        var scene = Fixtures.scene(id: 7)
        scene.videoPath = "/source/Cutaway.mp4"
        let folders = OutputFolders.build(records: [third, second, first], scenes: [scene],
            now: try #require(AIProvenance.parseDate("2026-09-20 15:00:00")), calendar: calendar)
        func folder(_ id: String) throws -> OutputFolder { try #require(folders.first { $0.id == id }) }
        #expect(try folder("all").videoIDs == [1, 2, 3])
        #expect(try folder("today").videoIDs == [1, 2])
        #expect(try folder("favorites").videoIDs == [1])
        #expect(folders.filter { $0.section == .date }.map(\.id) == ["date:2026-09-20", "date:2026-09-19"])
        #expect(try folder("source:Podcast.mp4").count == 2)
        #expect(try folder("source:Cutaway.mp4").videoIDs == [1])
        #expect(try folder("batch:run-a").videoIDs == [1, 2])
        #expect(try folder("batch:run-a").title.hasPrefix("Podcast highlights · "))
        #expect(try folder("batch:run-b").title.hasPrefix("Wizard · "))
        #expect(folders.filter { $0.section == .batch }.map(\.id) == ["batch:run-a", "batch:run-b"])
    }

    @Test func rememberedFolderAbsentFromCurrentProjectResolvesToAll() {
        let folders = OutputFolders.build(records: [Fixtures.generatedVideo(id: 1)], scenes: [])
        let restored = OutputFolders.resolvedSelection("source:Deleted.mp4", in: folders)
        #expect(restored == "all")
        #expect(OutputFolders.membership(for: restored, in: folders) == [1])
        #expect(OutputFolders.resolvedSelection("favorites", in: folders) == "favorites")
        #expect(OutputFolders.resolvedSelection(nil, in: folders) == "all")
        #expect(OutputFolders.membership(for: "all", in: folders) == [1])
        #expect(OutputFolders.membership(for: nil, in: folders) == [1])
    }

    @Test func largeLibraryDecodesEachRecordOnlyOnce() {
        let records = (1...500).map { id in
            var record = Fixtures.generatedVideo(id: Int64(id), batchID: "batch-\(id % 20)")
            record.timelineJSON = "{\"format_name\":\"podcast_highlights\",\"video_track\":[{\"video_file\":\"/source/\(id).mp4\"}]}"
            record.settingsJSON = "settings-\(id)"
            record.generatedAt = "2026-09-20 12:00:00"
            return record
        }
        var timelineDecodes: [String: Int] = [:], settingsDecodes: [String: Int] = [:]
        let folders = OutputFolders.build(records: records, scenes: [], decodeTimeline: { json in
            timelineDecodes[json, default: 0] += 1
            return try? JSONSerialization.jsonObject(with: Data(json.utf8))
        }, decodeSettings: { json in
            settingsDecodes[json, default: 0] += 1
            return nil
        })
        #expect(timelineDecodes.count == 500 && timelineDecodes.values.allSatisfy { $0 == 1 })
        #expect(settingsDecodes.count == 500 && settingsDecodes.values.allSatisfy { $0 == 1 })
        #expect(folders.filter { $0.section == .source }.count == 500)
        let batches = folders.filter { $0.section == .batch }
        #expect(batches.count == 20)
        #expect(batches.allSatisfy { $0.count == 25 && $0.title.hasPrefix("Podcast highlights · ") })
    }

    @Test func todayUsesLocalCalendarAndMalformedDatesStayBrowsable() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: -4 * 3600))
        var video = Fixtures.generatedVideo(id: 1)
        video.generatedAt = "2026-09-20 01:00:00" // September 19 locally.
        let unknown = Fixtures.generatedVideo(id: 2)
        let folders = OutputFolders.build(records: [video, unknown], scenes: [],
            now: try #require(AIProvenance.parseDate("2026-09-19 23:00:00")), calendar: calendar)
        #expect(folders.first { $0.id == "today" }?.videoIDs == [1])
        #expect(folders.first { $0.id == "date:2026-09-19" }?.videoIDs == [1])
        #expect(folders.first { $0.id == "date:unknown" }?.videoIDs == [2])
        #expect(OutputFolders.build(records: [], scenes: []).map(\.count) == [0, 0, 0])
    }
}
