import Foundation

/// Uses the normal timeline disk codec: runtime clip IDs are regenerated on decode.
nonisolated struct WizardBeforeRecord: Sendable, Equatable {
    var timelineID: Int64
    var runUUID: String
    var request: String
    var createdAt: String = Date.now.ISO8601Format()
    var documentJSON: String
    var appliedRevision: Int

    func document() throws -> TimelineDocument {
        try JSONDecoder().decode(TimelineDocument.self, from: Data(documentJSON.utf8))
    }
}
