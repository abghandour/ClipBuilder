import Testing
@testable import Clip_Builder

@Suite("Timelines assistant")
struct TimelinesAssistantTests {
    private func timeline(_ id: Int64, _ name: String, edited: String, wizard: Bool = false,
                          opened: Bool = true) -> TimelineRecord {
        TimelineRecord(id: id, projectID: 1, name: name, kind: wizard ? "wizard" : "builder", documentJSON: "{}",
                       createdAt: edited, editedAt: edited, viewStateJSON: opened ? "{}" : nil)
    }

    private func ids(_ s: TimelinesAssistant.Snapshot) -> [String] {
        TimelinesAssistant().suggestions(for: TimelinesAssistant.context(s)).map(\.id)
    }

    @Test func noTimelinesSuggestsTheWizard() {
        let rows = TimelinesAssistant().suggestions(for: TimelinesAssistant.context(.init()))
        #expect(rows.map(\.id) == ["timelines.none.empty"])
        #expect(rows.first?.actionID == "timelines.wizard")
    }

    @Test func quietWhenRenderedAndOpened() {
        #expect(ids(.init(count: 2, builders: 2, newest: "A")).isEmpty)
    }

    @Test func changedSinceExportSuggestsRender() {
        let rows = TimelinesAssistant().suggestions(for: TimelinesAssistant.context(
            .init(count: 2, builders: 2, newest: "A", changedSinceExport: 1, newestChanged: "A")))
        #expect(rows.map(\.id) == ["timelines.render.pending"])
        #expect(rows.first?.title == "Open A to render")
        #expect(rows.first?.actionID == "timelines.open.changed")
    }

    @Test func unopenedTimelineSuggestsOpening() {
        #expect(ids(.init(count: 1, wizards: 1, newest: "W", neverOpened: 1, newestNeverOpened: "W"))
                == ["timelines.open.newest"])
    }

    @Test func changedIgnoresWizardTimelinesAndOlderEdits() {
        let timelines = [timeline(1, "Old", edited: "2026-10-01 10:00:00"),
                         timeline(2, "New", edited: "2026-10-20 10:00:00"),
                         timeline(3, "Wiz", edited: "2026-10-21 10:00:00", wizard: true)]
        #expect(TimelinesAssistant.changed(timelines, lastExport: "2026-10-10 00:00:00").map(\.name) == ["New"])
        #expect(TimelinesAssistant.changed(timelines, lastExport: nil).map(\.name) == ["New", "Old"])
        #expect(TimelinesAssistant.byEdit(timelines).map(\.name) == ["Wiz", "New", "Old"])
    }

    @Test func routing() {
        #expect(TimelinesAssistant.route("Open the newest timeline") == "timelines.open.newest")
        #expect(TimelinesAssistant.route("Start a new timeline from the Wizard") == "timelines.wizard")
        #expect(TimelinesAssistant.route("Create an empty timeline") == "timelines.new")
        #expect(TimelinesAssistant.route("render the latest") == "timelines.open.changed")
        #expect(TimelinesAssistant.route("hello") == nil)
    }
}
