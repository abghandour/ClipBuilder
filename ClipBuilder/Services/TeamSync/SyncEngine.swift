import Foundation

/// Explicit, cancellable single-cycle foundation. Scheduling, UI and profile
/// attachment are Phase 1. Nothing instantiates this for unattached profiles.
actor SyncEngine {
    static let understoodSchemaVersion = 1

    enum Status: Sendable, Equatable {
        case idle, syncing, synced
        case pending(changes: Int)
        case offline(pending: Int)
        case needsUpdate(serverVersion: Int)
        case failed(String)
    }

    private let database: Database
    private let client: SupabaseClient
    private let scope: SyncScope
    private let batchSize: Int
    private var running = false
    private(set) var status: Status = .idle

    init(database: Database, client: SupabaseClient, scope: SyncScope, batchSize: Int = 200) {
        self.database = database
        self.client = client
        self.scope = scope
        self.batchSize = max(1, batchSize)
    }

    func sync() async throws {
        guard !running else { throw SyncError.alreadySyncing }
        running = true
        defer { running = false }
        status = .syncing
        do {
            // Gate before binding, queue seeding, acknowledgements or applies.
            let version = try await client.schemaVersion()
            guard version <= Self.understoodSchemaVersion else { throw SyncError.needsUpdate(version) }
            try Task.checkCancellation()
            try await database.bindSync(to: scope)
            while true {
                try Task.checkCancellation()
                let changes = try await database.pendingSyncChanges(scope: scope, limit: batchSize)
                if changes.isEmpty { break }
                for change in changes {
                    try Task.checkCancellation()
                    try await client.push(change.wire)
                    try await database.acknowledgeSyncChange(change)
                }
            }
            while true {
                try Task.checkCancellation()
                let cursor = try await database.syncCursor()
                let rows = try await client.pull(scope: scope, after: cursor, limit: batchSize)
                if rows.isEmpty { break }
                try Task.checkCancellation()
                try await database.applySyncRows(rows, scope: scope)
                // Continue until empty even if the server capped this page below
                // the requested limit. Each page and its cursor commit together.
            }
            let pending = try await database.syncPendingCount()
            status = pending == 0 ? .synced : .pending(changes: pending)
        } catch let error as SyncError {
            if case .needsUpdate(let version) = error { status = .needsUpdate(serverVersion: version) }
            else { status = .failed(error.localizedDescription) }
            throw error
        } catch is CancellationError {
            status = .idle
            throw CancellationError()
        } catch {
            if error is URLError { status = .offline(pending: (try? await database.syncPendingCount()) ?? 0) }
            else { status = .failed(error.localizedDescription) }
            throw error
        }
    }
}
