import Foundation

extension AppStore {
    /// Nil when saved; otherwise what went wrong, already in the error log.
    /// The caller keeps the drawing on screen until this says it is saved.
    func saveTelestration(_ record: TelestrationRecord) async -> String? {
        guard let database else { return "No library is open." }
        let profile = profileGeneration
        do {
            _ = try await database.saveTelestration(record)
            // A write that lands after a profile switch is not this profile's change.
            if profile == profileGeneration { telestrationRevision += 1 }
            return nil
        } catch {
            ErrorLog.record("Save drawing", error.localizedDescription)
            return error.localizedDescription
        }
    }

    func deleteTelestration(id: Int64) async -> String? {
        guard let database else { return "No library is open." }
        let profile = profileGeneration
        do {
            try await database.deleteTelestration(id: id)
            if profile == profileGeneration { telestrationRevision += 1 }
            return nil
        } catch {
            ErrorLog.record("Delete drawing", error.localizedDescription)
            return error.localizedDescription
        }
    }
}
