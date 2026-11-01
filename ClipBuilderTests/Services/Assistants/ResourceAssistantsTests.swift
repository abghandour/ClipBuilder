import Testing
@testable import Clip_Builder

@Suite("Resource page assistants")
struct ResourceAssistantsTests {
    // MARK: Screen Layouts

    private func layoutIDs(_ s: ScreenLayoutsAssistant.Snapshot) -> [String] {
        ScreenLayoutsAssistant().suggestions(for: ScreenLayoutsAssistant.context(s)).map(\.id)
    }

    @Test func layoutsQuietWhenSavedAndAllowed() {
        #expect(layoutIDs(.init(saved: 2, builtIn: 3, usable: 5, aiEnabled: true)).isEmpty)
    }

    @Test func noSavedLayoutSuggestsCreating() {
        #expect(layoutIDs(.init(saved: 0, builtIn: 3, usable: 0, aiEnabled: true)) == ["layouts.saved.none"])
    }

    @Test func usableLayoutsWithAIOffSuggestAllowing() {
        let rows = ScreenLayoutsAssistant().suggestions(for: ScreenLayoutsAssistant.context(.init(saved: 1, usable: 2)))
        #expect(rows.map(\.id) == ["layouts.ai.off"])
        #expect(rows.first?.kind == .setting)
        #expect(rows.first?.actionID == "layouts.ai.on")
    }

    @Test func layoutsRouting() {
        #expect(ScreenLayoutsAssistant.route("Create a new screen layout") == "layouts.new")
        #expect(ScreenLayoutsAssistant.route("Let the AI Wizard use my layouts") == "layouts.ai.on")
        #expect(ScreenLayoutsAssistant.route("Show the layout files in Finder") == "layouts.finder")
        #expect(ScreenLayoutsAssistant.route("hello") == nil)
    }

    // MARK: Transitions

    private func transitionIDs(_ s: TransitionsAssistant.Snapshot) -> [String] {
        TransitionsAssistant().suggestions(for: TransitionsAssistant.context(s)).map(\.id)
    }

    @Test func transitionsQuietWhenRenderedAndOpen() {
        #expect(transitionIDs(.init(effects: 10, previews: 10)).isEmpty)
        #expect(transitionIDs(.init(effects: 10, previews: 10, limited: true, allowed: 4)).isEmpty)
    }

    @Test func missingPreviewsSuggestRenderingUnlessRendering() {
        #expect(transitionIDs(.init(effects: 10, previews: 3)) == ["transitions.previews.missing"])
        #expect(transitionIDs(.init(effects: 10, previews: 3, rendering: true)).isEmpty)
    }

    @Test func hardCutsOnlySuggestsOpeningThePalette() {
        let rows = TransitionsAssistant().suggestions(for: TransitionsAssistant.context(
            .init(effects: 10, previews: 10, limited: true, allowed: 0)))
        #expect(rows.map(\.id) == ["transitions.palette.cutsOnly"])
        #expect(rows.first?.actionID == "transitions.palette.all")
    }

    @Test func transitionsRouting() {
        #expect(TransitionsAssistant.route("Render all transition previews") == "transitions.render")
        #expect(TransitionsAssistant.route("Let the AI choose any transition") == "transitions.palette.all")
        #expect(TransitionsAssistant.route("Use hard cuts only") == "transitions.palette.cuts")
        #expect(TransitionsAssistant.route("hello") == nil)
    }

    // MARK: Effects (Looks)

    @Test func looksSuggestRenderingMissingPreviews() {
        let assistant = LooksAssistant()
        #expect(assistant.suggestions(for: LooksAssistant.context(.init(available: 8, previews: 2))).map(\.id)
                == ["looks.previews.missing"])
        #expect(assistant.suggestions(for: LooksAssistant.context(.init(available: 8, previews: 8))).isEmpty)
        #expect(assistant.suggestions(for: LooksAssistant.context(.init(available: 8, previews: 2, rendering: true))).isEmpty)
        #expect(assistant.suggestions(for: LooksAssistant.context(.init())).isEmpty)
    }

    @Test func looksRouting() {
        #expect(LooksAssistant.route("Render all effect previews") == "looks.render")
        #expect(LooksAssistant.route("Change the sample video") == "looks.sample")
        #expect(LooksAssistant.route("hello") == nil)
    }

    // MARK: Text Looks

    private func textIDs(_ s: TextLooksAssistant.Snapshot) -> [String] {
        TextLooksAssistant().suggestions(for: TextLooksAssistant.context(s)).map(\.id)
    }

    @Test func noSavedStylesSuggestCreatingFromAFile() {
        let rows = TextLooksAssistant().suggestions(for: TextLooksAssistant.context(.init()))
        #expect(rows.map(\.id) == ["text.styles.none"])
        #expect(rows.first?.actionID == "text.create")
    }

    @Test func emptyCurrentTabSuggestsCreatingForIt() {
        #expect(textIDs(.init(tab: "Name tags", captionStyles: 2)) == ["text.tagStyles.none"])
        #expect(textIDs(.init(tab: "Captions", captionStyles: 2)).isEmpty)
        #expect(textIDs(.init(tab: "Overlays", captionStyles: 2)).isEmpty)
    }

    @MainActor @Test func textLooksTabsMatchTheView() {
        // The assistant names tabs by raw value; keep it in step with TextLooksTab.
        #expect(TextLooksTab.captions.rawValue == "Captions")
        #expect(TextLooksTab.tags.rawValue == "Name tags")
        #expect(TextLooksTab.named.rawValue == "Named styles")
        #expect(TextLooksTab(rawValue: "Overlays") == .overlays)
        #expect(TextLooksTab(rawValue: "Fonts") == .fonts)
    }

    @Test func textLooksRouting() {
        #expect(TextLooksAssistant.route("Create a caption style from a reference image") == "text.create")
        #expect(TextLooksAssistant.route("Show the name tag styles") == "text.tab.Name tags")
        #expect(TextLooksAssistant.route("show overlays") == "text.tab.Overlays")
        #expect(TextLooksAssistant.route("hello") == nil)
    }

    // MARK: Bumpers, Images, Music

    private func assetIDs(_ kind: AssetKind, _ s: AssetsAssistant.Snapshot) -> [String] {
        var s = s
        s.kind = kind
        return AssetsAssistant(kind: kind).suggestions(for: AssetsAssistant.context(s)).map(\.id)
    }

    @Test func emptyFolderSuggestsAddingFiles() {
        #expect(assetIDs(.music, .init()) == ["music.files.none"])
        #expect(assetIDs(.bumpers, .init()) == ["bumpers.files.none"])
        #expect(assetIDs(.music, .init(folders: 1)).isEmpty)
        #expect(assetIDs(.music, .init(files: 3)).isEmpty)
    }

    @Test func untaggedImagesSuggestTagging() {
        let rows = AssetsAssistant(kind: .images).suggestions(for: AssetsAssistant.context(.init(kind: .images, files: 5, untagged: 3)))
        #expect(rows.map(\.id) == ["images.tags.missing"])
        #expect(rows.first?.actionID == "images.tag")
        #expect(assetIDs(.images, .init(files: 5, untagged: 3, tagging: 2)).isEmpty)
        #expect(assetIDs(.images, .init(files: 5)).isEmpty)
        // Music never counts tags.
        #expect(assetIDs(.music, .init(files: 5, untagged: 3)).isEmpty)
    }

    @Test func assetsRouting() {
        #expect(AssetsAssistant.route("Tag every image with AI", kind: .images) == "images.tag")
        #expect(AssetsAssistant.route("Find images of the octagon", kind: .images) == "images.ask")
        #expect(AssetsAssistant.route("Add background music", kind: .music) == "music.add")
        #expect(AssetsAssistant.route("Make a new folder for outros", kind: .bumpers) == "bumpers.folder")
        #expect(AssetsAssistant.route("Show the music in Finder", kind: .music) == "music.finder")
        #expect(AssetsAssistant.route("tag these", kind: .music) == nil)
    }
}
