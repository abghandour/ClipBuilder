import Foundation

/// Cancellable, dependency-ordered multi-table cycle. Nothing instantiates this
/// for unattached profiles. The coordinator owns scheduling and admission.
actor SyncEngine {
    static let understoodSchemaVersion = 3

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
    private(set) var changedTables: Set<String> = []
    private(set) var status: Status = .idle

    init(database: Database, client: SupabaseClient, scope: SyncScope, batchSize: Int = 200) {
        self.database = database
        self.client = client
        self.scope = scope
        self.batchSize = max(1, batchSize)
    }

    private func pull(_ table: SyncTable, serverWinsThrough: Int64? = nil) async throws {
        while true {
            try Task.checkCancellation()
            let cursor = try await database.syncCursor(table: table)
            let rows = try await client.pull(scope: scope, after: cursor, limit: batchSize, table: table)
            if rows.isEmpty { return }
            try Task.checkCancellation()
            if try await database.applySyncRows(rows, scope: scope, table: table, serverWinsThrough: serverWinsThrough) {
                changedTables.insert(table.name)
            }
        }
    }

    func resolveAssets() async throws {
        if try await database.resolveSyncAssets() { changedTables.insert("library_asset_metadata") }
    }

    func sync(log: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        guard !running else { throw SyncError.alreadySyncing }
        running = true
        defer { running = false }
        status = .syncing
        changedTables = []
        do {
            // Gate before binding, queue seeding, acknowledgements or applies.
            let version = try await client.schemaVersion()
            guard version <= Self.understoodSchemaVersion else { throw SyncError.needsUpdate(version) }
            guard version >= Self.understoodSchemaVersion else { throw SyncError.serverNotReady }
            try Task.checkCancellation()
            try await database.bindSync(to: scope)
            try await database.canonicalizeSyncIdentities(scope: scope)
            try await database.beginSyncProfileAdoption()
            // Complete every initial pull before any upload. This state survives
            // cancellation/relaunch; matching queued local rows are discarded.
            let initial = try await database.initialSyncPending()
            if initial {
                let boundary = try await database.initialSyncBoundary()
                for table in SyncTable.all { try await pull(table, serverWinsThrough: boundary) }
            }
            for (index, table) in SyncTable.all.enumerated() {
                if try await database.retrySyncParents(scope: scope, table: table) {
                    changedTables.insert(table.name)
                }
                log("Syncing \(table.name)…")
                while true {
                    try Task.checkCancellation()
                    let changes = try await database.pendingSyncChanges(scope: scope, limit: batchSize, table: table)
                    if changes.isEmpty { break }
                    try Task.checkCancellation()
                    try await client.push(changes.map(\.wire), table: table)
                    try await database.acknowledgeSyncChanges(changes)
                }
                try await pull(table)
                // Self-referencing scenes can arrive before their parent in a batch.
                while try await database.retrySyncParents(scope: scope, table: table) {
                    changedTables.insert(table.name)
                }
                log("PROGRESS: \(Double(index + 1) / Double(SyncTable.all.count))")
            }
            try await database.completeInitialSync()
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
