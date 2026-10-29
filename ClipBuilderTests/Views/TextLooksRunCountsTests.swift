import Testing

@testable import Clip_Builder

struct TextLooksRunCountsTests {
    @Test func countsWizardBatchesAndDeduplicatesSharedLooks() async throws {
        let temp = try await TempDatabase()
        let db = temp.database
        var options = WizardOptions()
        options.captionStyleID = "caption-a"
        options.nameTagStyleID = "tag-a"
        options.pinnedOverlayTemplate = "Title"
        options.fixedOverlayTemplate = "Title"
        let settings = WizardRunSettings(options: options)
        for index in 0..<2 {
            _ = try await db.insertGeneratedVideo(
                path: "/tmp/look-count-\(index).mp4", duration: 3,
                timelineJSON: "{}", wizardProvider: "fixture", wizardModel: nil, batchID: "one-run", settings: settings)
        }
        _ = try await db.insertGeneratedVideo(
            path: "/tmp/look-count-second.mp4", duration: 3,
            timelineJSON: "{}", wizardProvider: "fixture", wizardModel: nil, batchID: "second-run", settings: settings)
        _ = try await db.insertGeneratedVideo(
            path: "/tmp/look-count-builder.mp4", duration: 3,
            timelineJSON: "{}", wizardProvider: nil, wizardModel: nil, settings: settings)
        let counts = try await db.textLookRunCounts(namedLinks: [
            .init(kind: "captions", style: "caption-a", namedID: "shared"),
            .init(kind: "tags", style: "tag-a", namedID: "shared"),
            .init(kind: "overlays", style: "Title", namedID: "overlay-shared")
        ])
        #expect(counts.captions["caption-a"] == 2)
        #expect(counts.tags["tag-a"] == 2)
        #expect(counts.overlays["Title"] == 2)
        #expect(counts.named["shared"] == 2)
        #expect(counts.named["overlay-shared"] == 2)
    }

    @Test func missingStyleReferencesCountAsProfileDefault() async throws {
        let temp = try await TempDatabase()
        _ = try await temp.database.insertGeneratedVideo(
            path: "/tmp/look-count-default.mp4", duration: 3,
            timelineJSON: "{}", wizardProvider: "fixture", wizardModel: nil, settings: WizardRunSettings(options: WizardOptions()))
        let counts = try await temp.database.textLookRunCounts()
        #expect(counts.captions["default"] == 1)
        #expect(counts.tags["default"] == 1)
        #expect(counts.overlays.isEmpty)
        #expect(counts.named.isEmpty)
    }
}
