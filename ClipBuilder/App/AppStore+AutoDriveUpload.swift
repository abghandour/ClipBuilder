import Foundation

extension AppStore {
    /// Serialize copies and scans for a profile. Otherwise the folder watcher
    /// can discover a project's import first and choose Home as its destination.
    func enqueueSourceDiscovery(profile: BrandProfile, operation: @escaping @MainActor () async -> Void) {
        let previous = sourceDiscoveryTasks[profile.profileName]
        sourceDiscoveryTasks[profile.profileName] = Task {
            await previous?.value
            await operation()
        }
    }

    /// Compare database snapshots, never the project-filtered UI list. Drive
    /// browser downloads have a Drive identity and are excluded by the policy.
    func scanSourcesForAutoUpload(
        profile: BrandProfile, database: Database, projectID: Int64? = nil
    ) async throws -> Analyzer.SourceScan {
        let before = try await database.fetchVideos()
        let scan = try await analyzer.scanSourceFolder(profile: profile, database: database)
        let after = try await database.fetchVideos()
        // Folder lookup and transfers must not hold up discovery or project membership.
        Task {
            do {
                let newVideos = await Task.detached(priority: .utility) {
                    AutoDriveUpload.newVideos(before: before, after: after)
                }.value
                let enabled = try await database.autoUploadNewSourcesEnabled()
                let attached = profile.teamID != nil && profile.profileID != nil
                if attached, enabled, !newVideos.isEmpty {
                    await googleDrive.attach(profile: profile, database: database)
                }
                let connected: Bool
                if case .connected = googleDrive.states[profile.profileName] { connected = true }
                else { connected = false }
                let decision = await Task.detached(priority: .utility) {
                    AutoDriveUpload.decide(
                        videos: newVideos, attached: attached, driveConnected: connected, enabled: enabled)
                }.value
                if let reason = decision.reason {
                    appendLog(\.analysisLog, ["Team: \(reason.rawValue)"])
                    if reason == .driveNotConnected, !newVideos.isEmpty, !didShowAutoDriveUploadNotice {
                        didShowAutoDriveUploadNotice = true
                        presentNotice("Google Drive", "Connect Google Drive so your team can download new sources")
                    }
                    return
                }
                let projects = try await database.fetchProjects()
                let project = projects.first { $0.id == projectID } ?? projects.first { $0.isHome }
                let projectName = project?.name ?? "Home"
                let folder = try await googleDrive.uploadFolder(profile: profile.profileName, project: projectName)
                // Another upload may have started or finished during folder lookup.
                var media: [DriveMedia] = []
                for candidate in decision.candidates {
                    if let current = try await database.video(id: candidate.id) {
                        media.append(current.driveMedia)
                    }
                }
                let candidates = GoogleDriveTransfers.uploadCandidates(media).filter {
                    googleDrive.uploadJob(for: $0, profile: profile.profileName) == nil
                }
                if candidates.isEmpty {
                    appendLog(\.analysisLog, ["Team: nothing new"])
                    return
                }
                googleDrive.enqueueUpload(candidates, folder: folder.id, profile: profile.profileName,
                                          projectID: project?.id, projectName: projectName)
                appendLog(\.analysisLog, ["Team: uploading \(candidates.count) new source(s) to Google Drive (\(folder.name))"])
            } catch {
                appendLog(\.analysisLog, ["Team: could not prepare Google Drive upload — \(error.userMessage)"])
                presentNotice("Google Drive upload", error.userMessage)
            }
        }
        return scan
    }
}
