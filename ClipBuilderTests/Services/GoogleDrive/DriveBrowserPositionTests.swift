import Foundation
import Testing
@testable import Clip_Builder

struct DriveBrowserPositionTests {
    @Test func roundTripsPerProfileAndKeepsOnlyTheFolderTrail() throws {
        let defaults = try #require(UserDefaults(suiteName: "DriveBrowserPositionTests.\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: "DriveBrowserPositionTests") }
        var folder = DriveFile(id: "f1", name: "PAX Folder", mimeType: "application/vnd.google-apps.folder")
        folder.thumbnailLink = "https://example.com/x"
        let position = DriveBrowserPosition(location: "Shared with me", driveID: nil, breadcrumbs: [folder])
        position.save(profile: "Peace Grappler", defaults: defaults)
        #expect(DriveBrowserPosition.load(profile: "Peace Grappler", defaults: defaults) == position)
        #expect(DriveBrowserPosition.load(profile: "Other", defaults: defaults) == nil)
        #expect(position.isWorthRestoring)
        #expect(!DriveBrowserPosition(location: "My Drive", driveID: nil, breadcrumbs: []).isWorthRestoring)
        #expect(!DriveBrowserPosition(location: "Shared drives", driveID: nil, breadcrumbs: []).isWorthRestoring)
        #expect(DriveBrowserPosition(location: "Recent", driveID: nil, breadcrumbs: []).isWorthRestoring)
        let shared = DriveBrowserPosition(location: "Shared drives", driveID: "d1",
            breadcrumbs: [DriveFile(id: "d1", name: "Team", mimeType: "application/vnd.google-apps.folder")])
        #expect(shared.isWorthRestoring)
    }
}
