import Foundation
import Observation

@MainActor @Observable
final class AssetSyncHome {
    nonisolated struct Selection: Codable, Sendable {
        var id: String
        var name: String
        var breadcrumb: String
    }
    let selection: Selection
    var isLost = false
    var isRefreshing = false
    var status = "Ready to refresh"
    @ObservationIgnored private var task: Task<Void, Never>?
    var canRefresh: Bool { !isLost && !isRefreshing }
    var rowStatus: String { isLost ? "Folder no longer available — choose again" : status }

    init(folder: DriveFile, breadcrumb: String) {
        selection = Selection(id: folder.id, name: folder.name, breadcrumb: breadcrumb)
    }

    private init(selection: Selection) { self.selection = selection }

    static func restore(json: String, database: Database) async -> AssetSyncHome? {
        guard let selection = try? JSONDecoder().decode(Selection.self, from: Data(json.utf8)) else { return nil }
        let home = AssetSyncHome(selection: selection)
        if let journal = try? await AssetSyncJournal.load(database: database, homeID: selection.id),
            let date = journal.lastRefresh, let summary = journal.summary
        {
            home.status = "Last refresh \(date.formatted(date: .abbreviated, time: .shortened)): \(summary)"
        }
        return home
    }

    func remember(database: Database) async throws {
        let json = String(decoding: try JSONEncoder().encode(selection), as: UTF8.self)
        try await database.setDriveSetting("assetSyncJournal", value: "")
        try await database.setDriveSetting("assetHome", value: json)
    }

    func validate(client: GoogleDriveClient) async throws -> Bool {
        do {
            let file = try await client.assetHomeMetadata(id: selection.id)
            isLost = file.trashed == true || !file.isFolder
        } catch GoogleDriveError.notFound { isLost = true }
        return !isLost
    }

    func stop() { task?.cancel() }

    func refresh(
        client: GoogleDriveClient, database: Database, transfers: GoogleDriveTransfers,
        profile: String, roots: AssetSyncRoots = AssetSyncRoots(), log: @escaping (String) -> Void
    ) {
        guard canRefresh else { return }
        isRefreshing = true
        status = "Refreshing… checking folder"
        task = Task {
            let group = UUID()
            transfers.beginAssetGroup(group) { [weak self] in self?.stop() }
            defer {
                transfers.endAssetGroup(group)
                isRefreshing = false
                task = nil
            }
            var executor: AssetSyncExecutor?
            do {
                guard try await validate(client: client) else {
                    log(rowStatus)
                    return
                }
                let journal = try await AssetSyncJournal.load(database: database, homeID: selection.id)
                let remote = try await AssetSyncInventory.remote(client: client, homeID: selection.id)
                let prepared = try await Self.prepare(roots: roots, remote: remote.entries, journal: journal)
                var plan = AssetSyncPlanner.plan(local: prepared.local, remote: remote.entries)
                plan.reports = remote.reports
                let runner = AssetSyncExecutor(
                    roots: roots, client: client, transfers: transfers,
                    profile: profile, group: group, journal: prepared.journal)
                executor = runner
                try await runner.run(
                    plan, remote: remote.entries, database: database,
                    progress: { done, total in
                        self.status = "Refreshing… \(done) of \(total)"
                    }, log: log)
                try Task.checkCancellation()
                runner.journal.lastRefresh = Date()
                runner.journal.summary = runner.summary
                try await runner.journal.save(database: database)
                status = "Last refresh \(Date().formatted(date: .abbreviated, time: .shortened)): \(runner.summary)"
                log(status)
            } catch {
                status =
                    error is CancellationError ? "Stopped — Refresh to continue" : GoogleDriveError.message(for: error)
                if let executor { status += ": \(executor.summary)" }
                transfers.assetReport(profile: profile, group: group, path: "Refresh", message: status)
                log(status)
            }
        }
    }

    /// Awaitable for callers/tests that need the entire group, including staging cleanup, to finish.
    func waitForRefresh() async { await task?.value }

    @concurrent nonisolated private static func prepare(
        roots: AssetSyncRoots, remote: [String: AssetSyncEntry],
        journal: AssetSyncJournal
    ) async throws
        -> (local: [String: AssetSyncEntry], journal: AssetSyncJournal)
    {
        var journal = journal
        let local = try AssetSyncInventory.local(roots: roots)
        let hashed = try AssetSyncInventory.hashingMatches(
            local: local, remote: remote, roots: roots, journal: &journal)
        return (hashed, journal)
    }
}
