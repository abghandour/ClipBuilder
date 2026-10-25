import Foundation
import Testing
@testable import Clip_Builder

@MainActor
struct EffectSamplePickerTests {
    @Test func itemsMatchCatalogNamesAndOrderWithinEveryGroup() {
        for tab in EffectSamplePicker.Page.looks.tabs {
            let expected = EffectCatalog.presets.filter { $0.group == tab.id }
            let items = EffectSamplePicker.Page.looks.items(for: tab.id)
            #expect(!items.isEmpty)
            #expect(items.map(\.id) == expected.map(\.id))
            #expect(items.map(\.title) == expected.map(\.name))
        }
        for tab in EffectSamplePicker.Page.transitions.tabs {
            let expected = TransitionCatalog.all.filter { $0.category.rawValue == tab.id }
            let items = EffectSamplePicker.Page.transitions.items(for: tab.id)
            #expect(!items.isEmpty)
            #expect(items.map(\.id) == expected.map(\.name))
            #expect(items.map(\.title) == expected.map(\.title))
        }
    }

    @Test func rememberedItemsResolveOnlyWithinTheirGroup() throws {
        for page in EffectSamplePicker.Page.allCases {
            for tab in page.tabs {
                let items = page.items(for: tab.id)
                let first = try #require(items.first)
                #expect(page.selectedItem("", for: tab.id) == first.id)
                #expect(page.selectedItem("removed-item", for: tab.id) == first.id)
                for item in items {
                    #expect(page.selectedItem(item.id, for: tab.id) == item.id)
                }
                let otherTab = try #require(page.tabs.first { $0.id != tab.id })
                let foreignItem = try #require(page.items(for: otherTab.id).last)
                #expect(page.selectedItem(foreignItem.id, for: tab.id) == first.id)
            }
            #expect(page.items(for: "removed-group").isEmpty)
            #expect(page.selectedItem("removed-item", for: "removed-group") == nil)
        }
    }

    @Test func previousAndNextFollowDisplayOrderAndClampAtBothEnds() throws {
        for page in EffectSamplePicker.Page.allCases {
            for tab in page.tabs {
                let items = page.items(for: tab.id)
                for (index, item) in items.enumerated() {
                    #expect(page.previousItem(item.id, for: tab.id) == items[max(0, index - 1)].id)
                    #expect(page.nextItem(item.id, for: tab.id) == items[min(items.count - 1, index + 1)].id)
                }
                let first = try #require(items.first)
                #expect(page.previousItem("removed-item", for: tab.id) == first.id)
                #expect(page.nextItem("removed-item", for: tab.id) == items[min(1, items.count - 1)].id)
            }
            #expect(page.previousItem("", for: "removed-group") == nil)
            #expect(page.nextItem("", for: "removed-group") == nil)
        }
        // Cut is a singleton: both navigation buttons must stay disabled.
        let page = EffectSamplePicker.Page.transitions
        let cut = try #require(page.items(for: "cut").first)
        #expect(page.items(for: "cut").count == 1)
        #expect(page.previousItem(cut.id, for: "cut") == cut.id)
        #expect(page.nextItem(cut.id, for: "cut") == cut.id)
    }

    @Test func itemDefaultsRoundTripIndependentlyOfPagesAndGroupDefaults() throws {
        let suite = "EffectSamplePickerItemsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(EffectSamplePicker.Page.looks.itemDefaultsKey == "looks.item")
        #expect(EffectSamplePicker.Page.transitions.itemDefaultsKey == "transitions.item")

        for page in EffectSamplePicker.Page.allCases {
            let tab = try #require(page.tabs.last)
            let item = try #require(page.items(for: tab.id).last)
            defaults.set(tab.id, forKey: page.defaultsKey)
            defaults.set(item.id, forKey: page.itemDefaultsKey)
        }
        let reopened = try #require(UserDefaults(suiteName: suite))
        for page in EffectSamplePicker.Page.allCases {
            let tab = try #require(page.tabs.last)
            let item = try #require(page.items(for: tab.id).last)
            #expect(reopened.string(forKey: page.defaultsKey) == tab.id)
            #expect(reopened.string(forKey: page.itemDefaultsKey) == item.id)
            #expect(page.selectedItem(reopened.string(forKey: page.itemDefaultsKey) ?? "", for: tab.id) == item.id)
        }
    }

    @Test func tabsMatchEveryCatalogSectionInDisplayOrder() {
        let looks = EffectSamplePicker.Page.looks.tabs
        #expect(looks.map(\.id) == EffectControls.groups)
        #expect(looks.map(\.title) == ["Effects", "Film", "Adjust", "Detail", "Stylize"])
        #expect(Set(looks.map(\.id)) == Set(EffectCatalog.presets.map(\.group)))
        #expect(looks.count == Set(looks.map(\.id)).count)

        let transitions = EffectSamplePicker.Page.transitions.tabs
        #expect(transitions.map(\.id) == TransitionEffect.Category.allCases.map(\.rawValue))
        #expect(transitions.map(\.title) == TransitionEffect.Category.allCases.map(\.title))
        #expect(Set(transitions.map(\.id)) == Set(TransitionCatalog.all.map { $0.category.rawValue }))
    }

    @Test func rememberedTabsRoundTripIndependentlyAndInvalidValuesFallBack() throws {
        let suite = "EffectSamplePickerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let looks = EffectSamplePicker.Page.looks
        let transitions = EffectSamplePicker.Page.transitions
        #expect(looks.defaultsKey == "looks.tab")
        #expect(transitions.defaultsKey == "transitions.tab")

        for page in EffectSamplePicker.Page.allCases {
            #expect(page.selectedTab(defaults.string(forKey: page.defaultsKey) ?? "") == page.tabs[0].id)
            for tab in page.tabs {
                defaults.set(tab.id, forKey: page.defaultsKey)
                let reopened = try #require(UserDefaults(suiteName: suite))
                #expect(page.selectedTab(reopened.string(forKey: page.defaultsKey) ?? "") == tab.id)
            }
            defaults.set("removed-section", forKey: page.defaultsKey)
            #expect(page.selectedTab(defaults.string(forKey: page.defaultsKey) ?? "") == page.tabs[0].id)
        }
        defaults.set("film", forKey: looks.defaultsKey)
        defaults.set("action", forKey: transitions.defaultsKey)
        #expect(looks.selectedTab(defaults.string(forKey: looks.defaultsKey) ?? "") == "film")
        #expect(transitions.selectedTab(defaults.string(forKey: transitions.defaultsKey) ?? "") == "action")
    }

    @Test func sourceEntriesRequireLocalFilesAndPreserveOrderAndMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.mp4")
        let secondURL = directory.appendingPathComponent("second.mov")
        try Data([0]).write(to: firstURL)
        try Data([1]).write(to: secondURL)

        var first = Fixtures.video(id: 20)
        first.path = firstURL.path
        first.filename = "Same display name.mp4"
        first.duration = 12.5
        // Actual local presence wins over stale synced flags.
        first.sourceAvailable = false
        var second = Fixtures.video(id: 10)
        second.path = secondURL.path
        second.filename = first.filename
        second.duration = 31
        var noPath = Fixtures.video(id: 30)
        noPath.path = nil
        var emptyPath = Fixtures.video(id: 40)
        emptyPath.path = ""
        var missing = Fixtures.video(id: 50)
        missing.path = directory.appendingPathComponent("missing.mp4").path
        missing.sourceAvailable = true
        missing.driveFileID = "remote-only"
        var folder = Fixtures.video(id: 60)
        folder.path = directory.path

        let entries = EffectSamplePicker.sources(from: [noPath, first, missing, emptyPath, second, folder])
        #expect(entries.map(\.id) == [20, 10])
        #expect(entries.map(\.url) == [firstURL, secondURL])
        #expect(entries.map(\.filename) == [first.filename, second.filename])
        #expect(entries.map(\.duration) == [12.5, 31])
        #expect(EffectSamplePicker.sources(from: []).isEmpty)
        #expect(EffectSamplePicker.sources(from: [noPath, emptyPath, missing, folder]).isEmpty)

        try FileManager.default.removeItem(at: firstURL)
        #expect(EffectSamplePicker.sources(from: [first, second]).map(\.id) == [10])
    }

    @Test func looksAndTransitionsShareVideoAWithoutChangingVideoB() {
        let originalA = URL(fileURLWithPath: "/tmp/original-a.mp4")
        let originalB = URL(fileURLWithPath: "/tmp/original-b.mp4")
        let replacement = URL(fileURLWithPath: "/tmp/replacement.mp4")
        let original = EffectSampleSet(videoA: originalA, videoB: originalB)
        let fromLooks = EffectSamplePicker.selecting(replacement, for: .look, in: original)
        let fromTransitions = EffectSamplePicker.selecting(replacement, for: .videoA, in: original)
        #expect(fromLooks == fromTransitions)
        #expect(fromLooks.videoA == replacement)
        #expect(fromLooks.videoB == originalB)

        let changedB = EffectSamplePicker.selecting(replacement, for: .videoB, in: fromLooks)
        #expect(changedB.videoA == fromLooks.videoA)
        #expect(changedB.videoB == replacement)
        let resetLook = EffectSamplePicker.selecting(nil, for: .look, in: changedB)
        #expect(resetLook.videoA == nil)
        #expect(resetLook.videoB == replacement)
        #expect(resetLook == EffectSamplePicker.selecting(nil, for: .videoA, in: changedB))
        let resetB = EffectSamplePicker.selecting(nil, for: .videoB, in: original)
        #expect(resetB.videoA == originalA)
        #expect(resetB.videoB == nil)
        #expect(EffectSamplePicker.selecting(nil, for: .videoB, in: resetLook).isDefault)
    }
}
