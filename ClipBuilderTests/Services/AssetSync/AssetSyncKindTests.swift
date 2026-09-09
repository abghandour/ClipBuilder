import Testing

@testable import Clip_Builder

struct AssetSyncKindTests {
    @Test func kindsAndFilters() {
        #expect(
            AssetSyncKind.allCases.map(\.folderName) == [
                "music", "fonts", "images", "bumpers", "overlays", "screen_crops",
            ])
        #expect(AssetSyncKind.accepts("music/Album/track.MP3", isFolder: false))
        #expect(AssetSyncKind.accepts("screen_crops/layout.json", isFolder: false))
        for path in [
            "music/.import-x/a.mp3", "music/.hidden.mp3", "music/../a.mp3", "effects/previews/a.mp4", "fonts/a.mp3",
            "overlays/a.txt",
        ] {
            #expect(!AssetSyncKind.accepts(path, isFolder: false))
        }
    }
}
