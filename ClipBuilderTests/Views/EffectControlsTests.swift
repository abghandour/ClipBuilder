import Foundation
import SwiftUI
import Testing
@testable import Clip_Builder

@MainActor
struct EffectControlsTests {
    @Test func trackNoneClearsLookAndPresetSelectionResetsParameters() {
        var value: EffectSpec? = .init(preset: "blur", params: ["sigma": 12], intensity: 0.5)
        let effect = Binding<EffectSpec?>(get: { value }, set: { value = $0 })
        let selection = EffectControls.selectionBinding(effect: effect, inherits: false)
        #expect(selection.wrappedValue == "blur")
        selection.wrappedValue = "none"
        #expect(value == nil)
        #expect(selection.wrappedValue == "none")
        selection.wrappedValue = "bw"
        #expect(value == EffectSpec(preset: "bw"))
        selection.wrappedValue = "unknown"
        #expect(value == EffectSpec(preset: "bw"))
    }

    @Test func clipInheritAndNoneAreDistinct() {
        var value: EffectSpec?
        let effect = Binding<EffectSpec?>(get: { value }, set: { value = $0 })
        let selection = EffectControls.selectionBinding(effect: effect, inherits: true)
        #expect(selection.wrappedValue == "inherit")
        selection.wrappedValue = "none"
        #expect(value?.preset == "none")
        #expect(selection.wrappedValue == "none")
        selection.wrappedValue = "sepia"
        #expect(value?.preset == "sepia")
        selection.wrappedValue = "inherit"
        #expect(value == nil)
    }

    @Test func parameterWritesClampAndPreserveIntensity() throws {
        let preset = try #require(EffectCatalog.preset(for: "blur"))
        let param = try #require(preset.params.first)
        var value: EffectSpec? = .init(preset: "blur", intensity: 0.4)
        let effect = Binding<EffectSpec?>(get: { value }, set: { value = $0 })
        let slider = EffectControls.parameterBinding(effect: effect, param: param)
        #expect(slider.wrappedValue == param.default)
        slider.wrappedValue = 8
        #expect(value?.params["sigma"] == 8)
        #expect(value?.intensity == 0.4)
        slider.wrappedValue = 100
        #expect(value?.params["sigma"] == param.max)
        slider.wrappedValue = -100
        #expect(value?.params["sigma"] == param.min)
        slider.wrappedValue = .nan
        #expect(value?.params["sigma"] == param.min)
        value = .init(preset: "bw")
        slider.wrappedValue = 10
        #expect(value?.params.isEmpty == true)
        value = nil
        slider.wrappedValue = 10
        #expect(value == nil)
    }

    @Test func intensityClampsWithoutChangingParameters() {
        var value: EffectSpec? = .init(preset: "blur", params: ["sigma": 8])
        let effect = Binding<EffectSpec?>(get: { value }, set: { value = $0 })
        let slider = EffectControls.intensityBinding(effect: effect)
        slider.wrappedValue = -1
        #expect(value?.intensity == 0)
        slider.wrappedValue = 2
        #expect(value?.intensity == 1)
        slider.wrappedValue = .infinity
        #expect(value?.intensity == 1)
        #expect(value?.params["sigma"] == 8)
    }

    @Test func previewWarningResolvesClipOverridesAndIgnoresEmptyTracks() {
        var document = TimelineDocument()
        #expect(!document.hasAnyEffect)
        document.trackSettings[0].effect = .init(preset: "bw")
        #expect(!document.hasAnyEffect)
        var clip = TimelineClip()
        clip.duration = 2
        document.videoTrack = [clip]
        #expect(document.hasAnyEffect)
        document.videoTrack[0].effect = .init(preset: "none")
        #expect(!document.hasAnyEffect)
        document.videoTrack[0].effect = .init(preset: "sepia", intensity: 0)
        #expect(!document.hasAnyEffect)
        document.videoTrack[0].effect = .init(preset: "sepia")
        document.trackSettings[0].effect = nil
        #expect(document.hasAnyEffect)
        document.videoTrack[0].bumper = true
        #expect(!document.hasAnyEffect)
        document.videoTrack[0].bumper = false
        document.videoTrack[0].duration = 0
        #expect(!document.hasAnyEffect)
    }

    @Test func previewWarningHandlesMissingSettingsAndMultipleTracks() {
        var document = TimelineDocument()
        var clip = TimelineClip()
        clip.track = 1
        clip.duration = 2
        document.videoTrack = [clip]
        document.trackSettings[0].effect = .init(preset: "bw")
        #expect(!document.hasAnyEffect)
        document.trackSettings[1].effect = .init(preset: "bw")
        #expect(document.hasAnyEffect)
        document.trackSettings = []
        #expect(!document.hasAnyEffect)
        document.videoTrack[0].effect = .init(preset: "invert")
        #expect(document.hasAnyEffect)
        document.videoTrack[0].track = -1
        #expect(document.hasAnyEffect)
    }

    @Test func previewWarningIgnoresClipsWithoutAnArea() {
        // Under Full Screen only track 0 has an area: a leftover clip on
        // track 1 is not drawn, so its look must not raise the badge.
        var document = TimelineDocument()
        var clip = TimelineClip()
        clip.track = 1
        clip.duration = 2
        clip.effect = .init(preset: "bw")
        document.videoTrack = [clip]
        document.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 10)]
        #expect(!document.hasAnyEffect)
        document.videoTrack[0].coverAllAreas = true
        #expect(document.hasAnyEffect)
        document.videoTrack[0].coverAllAreas = false
        document.cropBlocks = [CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"), startTime: 0, duration: 10)]
        #expect(document.hasAnyEffect == (document.cropBlocks[0].layout.areaCount > 1))
    }

    @Test func samplePathsAreStableAndVersioned() {
        let root = URL(fileURLWithPath: "/tmp/look-path-tests", isDirectory: true)
        let path = LookSamples.previewURL(for: "bw", directory: root, rendererVersion: "test-v1")
        #expect(path.lastPathComponent == "bw-vtest-v1.mp4")
        #expect(path == LookSamples.previewURL(for: "bw", directory: root, rendererVersion: "test-v1"))
        #expect(path != LookSamples.previewURL(for: "bw", directory: root, rendererVersion: "test-v2"))
        #expect(path != LookSamples.previewURL(for: "sepia", directory: root, rendererVersion: "test-v1"))
        let paths = EffectCatalog.ids.map { LookSamples.previewURL(for: $0, directory: root) }
        #expect(Set(paths).count == EffectCatalog.ids.count)
        #expect(paths.allSatisfy { $0.deletingLastPathComponent() == root })
    }

    @Test func sampleReceiptsInvalidateWhenSourceChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        try Data([0]).write(to: source)
        let key = try LookSamples.sampleKey(video: source)
        #expect(key == (try LookSamples.sampleKey(video: source)))
        let output = LookSamples.previewURL(for: "bw", directory: root)
        try Data([1]).write(to: output)
        #expect(!LookSamples.hasPreview(for: "bw", video: source, directory: root), "no receipt yet")
        try key.write(to: output.appendingPathExtension("sample"), atomically: true, encoding: .utf8)
        #expect(LookSamples.hasPreview(for: "bw", video: source, directory: root), "receipt matches")
        #expect(!LookSamples.hasPreview(for: "bw", video: nil, directory: root), "built-in card has a different key")
        // The key covers path, modification date and size; a bigger rewrite
        // changes the size even inside the same clock second.
        try Data([0, 1, 2]).write(to: source)
        let changed = try LookSamples.sampleKey(video: source)
        #expect(changed != key, "key follows the source file")
        #expect(!LookSamples.hasPreview(for: "bw", video: source, directory: root), "stale receipt")
    }

    @Test func sampleDocumentUsesAreaLookWithoutOtherDecorations() {
        let source = URL(fileURLWithPath: "/tmp/look-source.mp4")
        let document = LookSamples.document(source: source, duration: 2, presetID: "bw", wide: true)
        #expect(document.videoTrack.count == 1)
        #expect(document.videoTrack.first?.videoFile == source.path)
        #expect(document.videoTrack.first?.effect == nil)
        #expect(document.videoTrack.first?.cropXFrac == 0.5)
        #expect(document.videoTrack.first?.muted == true)
        #expect(document.trackSettings[0].effect?.preset == "bw")
        #expect(document.cropBlocks.first?.layout == .fullScreen)
        #expect(document.soundTrack.isEmpty && document.textOverlays.isEmpty && document.imageOverlays.isEmpty)
    }

    @Test func sidebarRawValuesRemainCompatible() {
        let existing: [(SidebarSection, String)] = [
            (.projects, "projects"), (.sources, "sources"), (.timelines, "timelines"),
            (.outputs, "outputs"), (.resources, "resources"), (.analyze, "analyze"),
            (.scenes, "scenes"), (.curated, "curated"), (.people, "people"),
            (.music, "music"), (.fonts, "fonts"), (.images, "images"),
            (.overlays, "overlays"), (.effects, "effects"), (.screenCrops, "screenCrops"),
            (.bumpers, "bumpers"), (.wizard, "wizard"), (.learned, "learned"),
            (.builder, "builder"), (.library, "library"), (.instagram, "instagram"),
            (.instagramReports, "instagramReports")
        ]
        for (section, value) in existing {
            #expect(section.rawValue == value)
            #expect(SidebarSection(rawValue: value) == section)
        }
        #expect(SidebarSection.allCases.count == existing.count + 1)
        #expect(SidebarSection.looks.rawValue == "looks")
        #expect(SidebarSection.looks.projectDestination == .looks)
        #expect(SidebarSection.effects.title == "Transitions")
        #expect(SidebarSection.looks.title == "Looks")
        #expect(SidebarSection.looks.shortcut == nil)
        let resources = SidebarSection.resourceSections
        let transitions = resources.firstIndex(of: .effects)
        #expect(transitions.map { resources[$0 + 1] } == .looks)
    }
}
