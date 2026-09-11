import Foundation

/// Attached only after the planned document has been saved and opened. The
/// result cannot offer fixes on a different timeline with a coincident ID.
@MainActor
struct BuilderPlanResult: Identifiable {
    let id = UUID()
    let timelineID: Int64?
    let projectID: Int64?
    let profile: String
    let database: Database?
    var openRequested: Bool

    init(store: AppStore, openRequested: Bool = false) {
        timelineID = store.builder.timelineID
        projectID = store.activeProjectID
        profile = store.builder.profileName
        database = store.database
        self.openRequested = openRequested
    }

    func matches(store: AppStore) -> Bool {
        timelineID != nil && store.builder.timelineID == timelineID
            && store.activeProjectID == projectID && store.builder.profileName == profile
            && store.database === database
    }

    func makeWizard(store: AppStore,
                    loadLibrary: (@MainActor () async throws -> ScriptLibrarySnapshot)? = nil) -> WizardSheetModel? {
        guard matches(store: store) else { return nil }
        // WizardPlan's rationale and cut reasons explain creative choices;
        // LastPlanRecord contains input prompts and outcomes, not follow-up
        // editing notes. Seed examples, never replay the original plan prompt.
        return WizardSheetModel(store: store, loadLibrary: loadLibrary, prefillExamples: true)
    }
}
