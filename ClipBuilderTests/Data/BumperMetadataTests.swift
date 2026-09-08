import Foundation
import Testing
@testable import Clip_Builder

@Suite("Bumper metadata and compatibility")
struct BumperMetadataTests {
    @Test("old documents and wizard snapshots default bumpers off")
    func oldDocuments() throws {
        let data = Data(#"{"video_track":[{"video_file":"/old.mp4","start":0,"end":3,"start_time":0}]}"#.utf8)
        let document = try JSONDecoder().decode(TimelineDocument.self, from: data)
        #expect(document.videoTrack.count == 1)
        #expect(document.videoTrack[0].bumper == false)
        let options = try JSONDecoder().decode(WizardOptions.self, from: Data("{}".utf8))
        #expect(!options.includeIntroBumper && !options.includeOutroBumper && !options.includeMiddleBumper)
    }

    @Test("bumper clips preserve identity and source span through Codable")
    func clipRoundTrip() throws {
        let asset = BumperAsset(path: "/subscribe.mov", displayName: "Subscribe", placements: [.anywhere], duration: 2)
        var clip = try #require(asset.clip(at: 4))
        clip.speed = 0.5
        clip.duration = 4
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: JSONEncoder().encode(clip))
        #expect(decoded.bumper && decoded.bumperName == "Subscribe")
        #expect(decoded.sceneID == nil && decoded.videoFile == asset.path)
        #expect(decoded.duration == 4 && decoded.sourceEnd == 2)
    }

    @Test("legacy metadata migration adds columns exactly once and placements round-trip")
    func migration() async throws {
        let temp = try TempDirectory(prefix: "BumperMigration")
        let path = temp.url.appendingPathComponent("legacy.db")
        let raw = try SQLiteConnection(path: path.path)
        try raw.executeScript("""
            CREATE TABLE library_asset_metadata (
                path TEXT PRIMARY KEY, kind TEXT NOT NULL,
                is_broll INTEGER NOT NULL DEFAULT 0,
                subjects_json TEXT NOT NULL DEFAULT '[]', tags_json TEXT NOT NULL DEFAULT '[]',
                provider TEXT, model TEXT, analyzed_at TEXT DEFAULT (datetime('now'))
            );
            INSERT INTO library_asset_metadata (path, kind) VALUES ('/legacy.mp4', 'bumpers');
            PRAGMA user_version = 7;
            """)
        let first = try Database(path: path)
        let columns = try raw.query("PRAGMA table_info(library_asset_metadata)")
        #expect(columns.count { $0["name"]?.stringValue == "display_name" } == 1)
        #expect(columns.count { $0["name"]?.stringValue == "placements_json" } == 1)
        let legacy = try #require(try await first.fetchAssetMetadata(kind: "bumpers").first)
        #expect(legacy.placements == nil && legacy.displayName == nil)
        try await first.saveBumper(path: "/legacy.mp4", displayName: "My Intro", placements: [.intro, .anywhere])
        let second = try Database(path: path)
        let saved = try #require(try await second.fetchAssetMetadata(kind: "bumpers").first)
        #expect(saved.displayName == "My Intro")
        #expect(Set(saved.placements ?? []) == ["intro", "anywhere"])
        #expect(try raw.query("PRAGMA table_info(library_asset_metadata)").count == columns.count)
        // Empty is distinct from nil: all placements explicitly disabled.
        try await second.saveBumper(path: "/legacy.mp4", displayName: "Unused", placements: [])
        let disabled = try #require(try await second.fetchAssetMetadata(kind: "bumpers").first)
        #expect(disabled.placements == [])
        let encoded = try JSONEncoder().encode(disabled)
        #expect(try JSONDecoder().decode(LibraryAssetMetadata.self, from: encoded) == disabled)
    }
}
