import Foundation

nonisolated struct TimelineRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var projectID: Int64
    var name: String
    var kind: String
    var documentJSON: String
    var createdAt: String?
    var editedAt: String?
    var sourceRunID: String?
    var thumbnailVideoID: Int64?
    var thumbnailPath: String?
    /// Where the editor was when this timeline was last open (JSON of
    /// `TimelineViewState`); nil for a timeline never opened.
    var viewStateJSON: String?

    var isWizard: Bool { kind == "wizard" }

    var viewState: TimelineViewState? {
        viewStateJSON?.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(TimelineViewState.self, from: $0) }
    }

    var document: TimelineDocument? {
        documentJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(TimelineDocument.self, from: $0) }
    }

    var duration: Double {
        guard let document else { return 0 }
        let clipEnd = document.videoTrack.map { $0.startTime + $0.duration }.max() ?? 0
        let soundEnd = document.soundTrack.map { $0.startTime + $0.duration }.max() ?? 0
        let textEnd = document.textOverlays.map(\.endTime).max() ?? 0
        let imageEnd = document.imageOverlays.map(\.endTime).max() ?? 0
        let blockEnd = document.overlayBlocks.map(\.endTime).max() ?? 0
        return max(clipEnd, soundEnd, textEnd, imageEnd, blockEnd)
    }

    var clipCount: Int { document?.videoTrack.count ?? 0 }
    var editedDate: Date? { Database.parseSQLiteDate(editedAt) }
}

/// The Builder's viewport for one timeline — playhead, zoom, selection,
/// focused track, and scroll — kept per timeline so switching between them
/// (or relaunching) lands where each one was left.
nonisolated struct TimelineViewState: Codable, Sendable, Equatable {
    var playhead = 0.0
    var zoom = 60.0
    var selection: TimelineSelection?
    var focusedTrack: Int?
    var scrollX = 0.0
    var scrollY = 0.0
}
