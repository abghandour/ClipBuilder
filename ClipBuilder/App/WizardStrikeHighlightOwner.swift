import Foundation

/// Like the dub review bridge, this keeps the engine from owning AppStore.
@MainActor
final class WizardStrikeHighlightOwner {
    weak var store: AppStore?

    func context(database: Database) -> WizardStrikeHighlightContext {
        let generation = store?.profileGeneration
        return WizardStrikeHighlightContext(isCurrent: { @MainActor [weak self] in
            guard let store = self?.store else { return false }
            return generation == store.profileGeneration && store.database === database
        }, didSave: { @MainActor [weak self] in
            guard let store = self?.store, generation == store.profileGeneration,
                  store.database === database else { return }
            store.strikeHighlightRevision += 1
        }, marking: { @MainActor [weak self] videoID, running in
            guard let store = self?.store, generation == store.profileGeneration,
                  store.database === database else { return }
            if running { store.wizardStrikeMarkingInFlight.insert(videoID) }
            else { store.wizardStrikeMarkingInFlight.remove(videoID) }
        })
    }
}
