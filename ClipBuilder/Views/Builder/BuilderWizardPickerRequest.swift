import Foundation

/// A find's immutable scope survives closing its sheet. Scene IDs are only
/// meaningful in this captured Library and timeline, never another profile.
@MainActor
struct BuilderWizardPickerRequest {
    let request: String
    let scenes: [SceneRecord]
    let context: ParserContext
    let revision: Int
    let profile: String
    let timelineID: Int64?
    let database: Database?

    let time: Double
    let track: Int

    func validate(store: AppStore) throws {
        guard store.database === database, store.builder.profileName == profile,
              store.builder.timelineID == timelineID,
              store.activeProjectID == context.library.projectID else { throw ApplyFailure.identityChanged }
        guard store.builder.revision == revision,
              TimelineDiff(before: context.document, after: store.builder.document).isEmpty else {
            throw ApplyFailure.staleRevision
        }
    }
}
