import Foundation
import Testing
@testable import Clip_Builder

@Suite("Highlight history navigation")
struct HighlightHistoryNavigationTests {
    private let utcStyle: Date.FormatStyle = {
        Date.FormatStyle(locale: Locale(identifier: "en_US_POSIX"), calendar: Calendar(identifier: .gregorian),
                         timeZone: TimeZone(identifier: "UTC")!).year().month(.twoDigits).day(.twoDigits)
    }()

    private func record(id: Int64 = 1, flow: WizardHighlightFlow = .expressHighlights, author: String? = "ana@example.com",
                        note: String? = nil, settings: WizardHighlightSettings? = nil,
                        hashes: [String]? = ["A"], createdAt: String? = "2026-11-01 13:05:00") -> WizardHighlightRecord {
        let json = settings.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        return WizardHighlightRecord(id: id, projectID: 1, flow: flow.rawValue, videoHashes: hashes,
                                     settingsJSON: json, note: note, author: author, createdAt: createdAt)
    }

    private func video(_ id: Int64, hash: String, path: String) -> VideoRecord {
        var video = Fixtures.video(id: id)
        video.hash = hash
        video.path = path
        return video
    }

    @Test func labelIsDateTitleAndRequest() {
        var options = WizardOptions()
        options.aiInstructions = "find a funny part in this transcript and add it to the reel please"
        let settings = WizardHighlightSettings(options: options, length: MiniWizardFlow.Length.fifteen.rawValue)
        var plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: 1, start: 0, end: 2)])
        plan.headline = "7 guys said no. I'll fight anybody."
        var entry = record(settings: settings)
        entry.planJSON = String(decoding: try! JSONEncoder().encode(plan), as: UTF8.self)
        let label = HighlightHistoryNavigation.label(for: entry, dateStyle: utcStyle)
        let day = Date(timeIntervalSince1970: 1_793_538_300).formatted(utcStyle)  // 2026-11-01 13:05 UTC
        #expect(label == "\(day) · 7 guys said no. I'll fight anybody. · find a funny part in this transcript…")
        #expect(!label.contains("ana@example.com") && !label.contains("Express") && !label.contains("15 s"))
        #expect(HighlightHistoryNavigation.detail(for: entry) == "ana@example.com · Express highlights · 15 s")
        #expect(HighlightHistoryNavigation.shortLabel(for: entry, dateStyle: utcStyle)
                == "\(day) · 7 guys said no. I'll fight anybody.")
    }

    @Test func regenerateNoteBeatsInstructions() {
        var options = WizardOptions()
        options.aiInstructions = "find a funny part"
        let entry = record(note: "Tighter opening\nand a punchier end", settings: WizardHighlightSettings(options: options))
        #expect(HighlightHistoryNavigation.request(entry) == "Tighter opening and a punchier end")
    }

    @Test func labelLeavesOutMissingParts() {
        let label = HighlightHistoryNavigation.label(for: record(flow: .fullAutomatic, author: "  ", createdAt: nil),
                                                     dateStyle: utcStyle)
        #expect(label == "")
        #expect(HighlightHistoryNavigation.detail(for: record(flow: .fullAutomatic, author: "  ")) == "AI Wizard")
    }

    @Test func shortDateDropsWhatTheReaderKnows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_538_300)  // 2026-11-01 13:05 UTC
        let sameDay = HighlightHistoryNavigation.shortDate(now.addingTimeInterval(-3600), now: now, calendar: calendar)
        #expect(!sameDay.contains("Nov") && !sameDay.contains("2026"))
        let sameYear = HighlightHistoryNavigation.shortDate(now.addingTimeInterval(-86400 * 40), now: now, calendar: calendar)
        #expect(sameYear.contains("Sep") && !sameYear.contains("2026"))
        let lastYear = HighlightHistoryNavigation.shortDate(now.addingTimeInterval(-86400 * 400), now: now, calendar: calendar)
        #expect(lastYear.contains("2025"))
    }

    @Test func fullWizardShowsRecipeOrTargetDuration() {
        var options = WizardOptions()
        options.formatPreset = ReelRecipe.podcastHighlights.id
        #expect(HighlightHistoryNavigation.lengthOrRecipe(WizardHighlightSettings(options: options))
                == ReelRecipe.podcastHighlights.title)
        options.formatPreset = "custom"
        options.targetDurationSeconds = 30
        #expect(HighlightHistoryNavigation.lengthOrRecipe(WizardHighlightSettings(options: options)) == "30 s")
        options.targetDurationSeconds = nil
        #expect(HighlightHistoryNavigation.lengthOrRecipe(WizardHighlightSettings(options: options)) == nil)
    }

    @Test func noteExcerptIsAtMostFortyCharacters() {
        let long = String(repeating: "word ", count: 20)
        let excerpt = HighlightHistoryNavigation.noteExcerpt(long)
        #expect(excerpt?.count ?? 0 <= HighlightHistoryNavigation.noteExcerptLength)
        #expect(excerpt?.hasSuffix("…") == true)
        #expect(HighlightHistoryNavigation.noteExcerpt("   \n ") == nil)
        #expect(HighlightHistoryNavigation.noteExcerpt("short") == "short")
    }

    @Test func flowLabelKeepsUnknownFlows() {
        #expect(HighlightHistoryNavigation.flowLabel("expressQA") == "Express Q&A")
        #expect(HighlightHistoryNavigation.flowLabel("futureFlow") == "futureFlow")
        #expect(HighlightHistoryNavigation.flowLabel("") == "Highlight")
    }

    @Test func createdAtParsesAsUTC() throws {
        let date = try #require(HighlightHistoryNavigation.date(from: "2026-11-01 13:05:00"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(parts.year == 2026 && parts.month == 11 && parts.day == 1 && parts.hour == 13 && parts.minute == 5)
        #expect(HighlightHistoryNavigation.date(from: "not a date") == nil)
        #expect(HighlightHistoryNavigation.date(from: nil) == nil)
    }

    @Test func previousStepsOlderAndNextStepsNewer() {
        // Newest first: index 0 is the newest entry.
        #expect(HighlightHistoryNavigation.previousIndex(current: nil, count: 3) == 0)
        #expect(HighlightHistoryNavigation.previousIndex(current: 0, count: 3) == 1)
        #expect(HighlightHistoryNavigation.previousIndex(current: 2, count: 3) == nil)
        #expect(HighlightHistoryNavigation.previousIndex(current: nil, count: 0) == nil)
        #expect(HighlightHistoryNavigation.nextIndex(current: 2, count: 3) == 1)
        #expect(HighlightHistoryNavigation.nextIndex(current: 0, count: 3) == nil)
        #expect(HighlightHistoryNavigation.nextIndex(current: nil, count: 3) == nil)
        #expect(HighlightHistoryNavigation.nextIndex(current: 5, count: 3) == nil)
    }

    @Test func entriesWithAMissingVideoAreUnavailable() {
        let records = [record(id: 1, hashes: ["A"]), record(id: 2, hashes: ["A", "Z"]), record(id: 3, hashes: nil)]
        #expect(HighlightHistoryNavigation.unavailableIDs(records, localHashes: ["A"]) == [2])
    }

    @Test func planSummaryCountsClipsAndPlayedSeconds() {
        var fast = Fixtures.planClip(sceneID: 2, start: 0, end: 10)
        fast.speed = 2
        let plan = Fixtures.plan(clips: [Fixtures.planClip(start: 2, end: 6), fast])
        #expect(HighlightHistoryNavigation.planSummary(plan) == "2 clips · 9 s")
        #expect(HighlightHistoryNavigation.planSummary(Fixtures.plan(clips: [])) == nil)
        #expect(HighlightHistoryNavigation.planSummary(nil) == nil)
    }

    @Test func localOptionsKeepKnownPathsAndRemapByHash() {
        var options = WizardOptions()
        options.sourcesRestricted = true
        options.sourceVideoPaths = ["/Users/ana/A.mov", "/Users/ana/B.mov"]
        options.sourceSceneIDs = [4, 5]
        let local = [video(1, hash: "A", path: "/Users/me/A.mov"), video(2, hash: "B", path: "/Users/me/B.mov"),
                     video(3, hash: "C", path: "/Users/me/C.mov")]
        let remapped = HighlightHistoryNavigation.localOptions(options, videoHashes: ["A", "B"], localVideos: local,
                                                               projectID: 9)
        #expect(remapped.sourceVideoPaths == ["/Users/me/A.mov", "/Users/me/B.mov"])
        #expect(remapped.sourceSceneIDs.isEmpty)
        #expect(remapped.projectID == 9)

        // This Mac's own row keeps its paths and scene ids.
        options.sourceVideoPaths = ["/Users/me/C.mov"]
        let same = HighlightHistoryNavigation.localOptions(options, videoHashes: ["C"], localVideos: local, projectID: 9)
        #expect(same.sourceVideoPaths == ["/Users/me/C.mov"])
        #expect(same.sourceSceneIDs == [4, 5])
    }

    /// Team Sync strips `sourceVideoPaths` from settings_json before upload,
    /// so a teammate's options decode with no paths; Open rebuilds them by
    /// hash and drops the other Mac's scene and batch ids.
    @Test func localOptionsRebuildPathsAfterTheSyncStrip() throws {
        var options = WizardOptions()
        options.sourcesRestricted = true
        options.sourceVideoPaths = ["/Users/ana/A.mov"]
        options.sourceSceneSelection = true
        options.sourceSceneIDs = [4, 5]
        options.selectedRunIDs = [7]
        let settings = WizardHighlightSettings(options: options)
        let json = try JSONDecoder().decode(SyncJSON.self, from: JSONEncoder().encode(settings))
        let wire = try SyncMapping.portableJSONString(json)
        #expect(!wire.contains("sourceVideoPaths"))
        let pulled = try JSONDecoder().decode(WizardHighlightSettings.self, from: Data(wire.utf8))
        #expect(pulled.options.sourceVideoPaths.isEmpty)
        #expect(pulled.options.sourceSceneIDs == [4, 5])

        let local = [video(1, hash: "A", path: "/Users/me/A.mov"), video(2, hash: "B", path: "/Users/me/B.mov")]
        let opened = HighlightHistoryNavigation.localOptions(pulled.options, videoHashes: ["A"], localVideos: local,
                                                             projectID: 3, author: "ana@example.com",
                                                             localAuthor: "me@example.com")
        #expect(opened.sourceVideoPaths == ["/Users/me/A.mov"])
        #expect(opened.sourcesRestricted)
        #expect(opened.sourceSceneIDs.isEmpty)
        #expect(opened.selectedRunIDs.isEmpty)
        #expect(!opened.sourceSceneSelection)
        #expect(opened.projectID == 3)

        // A teammate's unrestricted run keeps no paths, but still drops their ids.
        var open = pulled.options
        open.sourcesRestricted = false
        let unrestricted = HighlightHistoryNavigation.localOptions(open, videoHashes: ["A"], localVideos: local,
                                                                   projectID: 3, author: "ana@example.com",
                                                                   localAuthor: "me@example.com")
        #expect(unrestricted.sourceVideoPaths.isEmpty)
        #expect(unrestricted.sourceSceneIDs.isEmpty && unrestricted.selectedRunIDs.isEmpty)
    }

    @Test func scopesSplitExpressBySourceFromTheFullWizard() {
        let express = HighlightHistoryScope.express(projectID: 1, videoHash: "A")
        let full = HighlightHistoryScope.fullWizard(projectID: 1)
        #expect(express.includes(record(flow: .expressQA, hashes: ["A"])))
        #expect(!express.includes(record(flow: .expressQA, hashes: ["B"])))
        #expect(!express.includes(record(flow: .fullAutomatic, hashes: ["A"])))
        #expect(full.includes(record(flow: .fullSelection, hashes: ["B"])))
        #expect(!full.includes(record(flow: .expressHighlights)))
        #expect(!HighlightHistoryScope.fullWizard(projectID: 2).includes(record(flow: .fullAutomatic)))
    }
}
