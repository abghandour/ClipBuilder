import Foundation
import Testing

@testable import Clip_Builder

struct DriveBrowserFilterTests {
    private func video(_ name: String, width: Int? = nil, height: Int? = nil, bytes: Int64 = 1,
                       millis: String? = nil, modified: String? = nil) -> DriveFile {
        var file = DriveFile(id: name, name: name, mimeType: "video/mp4")
        file.size = String(bytes)
        file.modifiedTime = modified
        if width != nil || height != nil || millis != nil {
            file.videoMediaMetadata = DriveVideoMetadata(width: width, height: height, durationMillis: millis)
        }
        return file
    }
    private func folder(_ name: String) -> DriveFile {
        DriveFile(id: "folder-\(name)", name: name, mimeType: "application/vnd.google-apps.folder")
    }

    @Test func decodesVideoMetadataAndClassifiesShape() throws {
        let json = Data(#"""
        {"id":"v","name":"clip.mov","mimeType":"video/quicktime","size":"10",
         "videoMediaMetadata":{"width":1920,"height":1080,"durationMillis":"90500"}}
        """#.utf8)
        let file = try JSONDecoder().decode(DriveFile.self, from: json)
        #expect(file.shape == .wide)
        #expect(file.durationSeconds == 90.5)
        #expect(video("t", width: 1080, height: 1920).shape == .tall)
        #expect(video("s", width: 1080, height: 1080).shape == .square)
        #expect(video("u").shape == .unknown)
        #expect(video("z", width: 0, height: 1080).shape == .unknown)
    }

    @Test func shapeFilterKeepsFoldersAndCountsUnknowns() {
        var filter = DriveBrowserFilter()
        filter.shape = .wide
        let result = filter.apply(to: [
            video("tall", width: 1080, height: 1920), folder("B"), video("wide", width: 1920, height: 1080),
            video("unknown"), folder("A"),
        ])
        #expect(result.files.map(\.name) == ["A", "B", "wide"])
        #expect(result.unknownShapeHidden == 1)
        #expect(filter.isActive)
        #expect(!DriveBrowserFilter().isActive)
    }

    @Test func minimumSizeDropsSmallFilesOnly() {
        var filter = DriveBrowserFilter()
        filter.minimumSize = .mb500
        let result = filter.apply(to: [
            video("small", bytes: 400_000_000), video("big", bytes: 600_000_000), folder("F"),
        ])
        #expect(result.files.map(\.name) == ["F", "big"])
        #expect(result.unknownShapeHidden == 0)
    }

    @Test func sortsWithinVideosAndFoldersStayFirst() {
        let files = [
            video("b", bytes: 5, millis: "2000", modified: "2026-09-01T00:00:00Z"),
            folder("z"),
            video("a", bytes: 9, millis: "1000", modified: "2026-09-03T00:00:00Z"),
            video("c", bytes: 7, modified: "2026-09-02T00:00:00Z"),
        ]
        var filter = DriveBrowserFilter()
        #expect(filter.apply(to: files).files.map(\.name) == ["z", "a", "b", "c"])
        filter.sort = .largest
        #expect(filter.apply(to: files).files.map(\.name) == ["z", "a", "c", "b"])
        filter.sort = .newest
        #expect(filter.apply(to: files).files.map(\.name) == ["z", "a", "c", "b"])
        filter.sort = .longest
        // Unknown durations sort last.
        #expect(filter.apply(to: files).files.map(\.name) == ["z", "b", "a", "c"])
    }

    @Test func listRequestsVideoDimensions() {
        #expect(GoogleDriveClient.fields.contains("videoMediaMetadata/width"))
        #expect(GoogleDriveClient.fields.contains("videoMediaMetadata/durationMillis"))
    }
}
