import Foundation
import Synchronization

/// Only value data crosses from AppStore to the kit's send-time callback.
nonisolated struct BugReportContext: Sendable, Equatable {
    var profile = ""
    var project = ""
    var section = ""
    var version = ""
    var build = ""
    var ffmpegVersion: String?
    var driveConnected = false
    var instagramConnected = false
    var dataFolder = ""
    var recentStatus: [String] = []

    var fields: [String: String] {
        var result = [
            "profile": profile, "project": project, "section": section,
            "version": version, "build": build,
            "driveConnected": String(driveConnected),
            "instagramConnected": String(instagramConnected),
            "dataFolder": dataFolder,
            "recentStatus": recentStatus.suffix(3).joined(separator: "\n"),
        ]
        if let ffmpegVersion { result["ffmpegVersion"] = ffmpegVersion }
        return result
    }
}

nonisolated final class BugReportContextSnapshot: Sendable {
    private let value = Mutex(BugReportContext())

    func update(_ snapshot: BugReportContext) {
        value.withLock { $0 = snapshot }
    }

    func read() -> BugReportContext {
        value.withLock { $0 }
    }
}
