import Foundation

nonisolated enum ApplyFailure: Error, Equatable {
    case staleRevision
    case identityChanged
    case missingUndoManager
    case candidateChanged
    case notApplicable
    case commitInProgress
    case missingBeforeVersion
    case persistence(String)
}

/// The approved value plus its immutable preview and captured owner. Ordinary
/// TimelineDocument JSON is still the on-disk format; this is an in-memory token.
nonisolated struct BuilderScriptSnapshot: Sendable {
    var document: TimelineDocument
    let preview: TimelineDocument
    let timelineID: Int64?
    let profileName: String
    let runUUID: String

    init(document: TimelineDocument, timelineID: Int64?, profileName: String, runUUID: String) {
        self.document = document
        preview = document
        self.timelineID = timelineID
        self.profileName = profileName
        self.runUUID = runUUID
    }
}
