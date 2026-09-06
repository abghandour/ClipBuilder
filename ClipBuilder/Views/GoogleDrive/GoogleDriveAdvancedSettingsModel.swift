import Foundation
import Observation

@MainActor @Observable
final class GoogleDriveAdvancedSettingsModel {
    enum Source: Equatable {
        case checking, personal, builtIn, unavailable

        var description: String {
            switch self {
            case .checking: "Checking connection settings…"
            case .personal: "Using your own credentials (saved on this Mac)"
            case .builtIn: "Using the app's built-in settings"
            case .unavailable: "This copy of Clip Builder has no built-in Google settings."
            }
        }
    }

    @ObservationIgnored private var revision = 0

    var clientID = ""
    var clientSecret = ""
    private(set) var source = Source.checking
    private(set) var message: String?
    private(set) var saving = false

    var canSave: Bool {
        !saving && !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load(auth: GoogleDriveAuth) async {
        let expectedRevision = revision
        do {
            let saved = try await auth.applicationOverride()
            let configured = await auth.configuration.isConfigured
            guard revision == expectedRevision else { return }
            source = saved != nil ? .personal : configured ? .builtIn : .unavailable
            // A delayed initial read must not overwrite edits already underway.
            if clientID.isEmpty && clientSecret.isEmpty && !saving, let saved {
                clientID = saved.clientID
                clientSecret = saved.clientSecret
            }
        } catch { message = GoogleDriveError.message(for: error) }
    }

    func save(clear: Bool, drive: GoogleDriveTransfers, activeProfile: String) async {
        guard !saving else { return }
        guard clear || canSave else {
            message = "Enter both fields before saving."
            return
        }
        revision += 1
        saving = true
        message = nil
        defer { saving = false }
        do {
            try await drive.auth.saveApplicationOverride(
                clear ? nil : .init(clientID: clientID, clientSecret: clientSecret))
            if clear {
                clientID = ""
                clientSecret = ""
                let configured = await drive.auth.configuration.isConfigured
                source = configured ? .builtIn : .unavailable
                message =
                    configured
                    ? "Using the app's built-in settings."
                    : "This copy of Clip Builder has no built-in Google settings."
            } else {
                source = .personal
                message = "Saved. Google Drive is ready to connect."
            }
            await drive.refreshAllStates(including: activeProfile)
        } catch {
            // Keep both fields and the last confirmed source on any write failure.
            message = GoogleDriveError.message(for: error)
        }
    }
}
