import Foundation
import Observation

@MainActor @Observable
final class ProviderStatusModel {
    typealias Locate = @Sendable (String) -> URL?
    typealias Status = @Sendable (String, URL) async -> ProviderAuth.State

    private(set) var items: [ProviderStatusItem] = []
    @ObservationIgnored private let locate: Locate
    @ObservationIgnored private let status: Status
    @ObservationIgnored private var lastRefresh: ContinuousClock.Instant?
    @ObservationIgnored private var pollingUntil: ContinuousClock.Instant?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshRequested = false

    init(
        locate: @escaping Locate = { ProcessRunner.locate($0) },
        status: @escaping Status = { await ProviderAuth.status(provider: $0, binary: $1, timeout: 10) }
    ) {
        self.locate = locate
        self.status = status
    }

    func didOpenSignIn() {
        pollingUntil = .now.advanced(by: .seconds(120))
        refreshRequested = true
    }

    /// Activation and sign-in bypass the ordinary one-minute throttle.
    /// Coalesce requests received during a scan into the next refresh.
    func refresh(binaries: [String: String], force: Bool = false) async {
        if force { refreshRequested = true }
        guard !refreshing else { return }
        let now = ContinuousClock.now
        let polling = pollingUntil.map { now < $0 } ?? false
        let interval: Duration = polling ? .seconds(5) : .seconds(60)
        guard refreshRequested || lastRefresh == nil
            || lastRefresh.map({ $0.duration(to: now) >= interval }) == true else { return }
        refreshRequested = false
        refreshing = true
        lastRefresh = now
        defer { refreshing = false }
        let result = await Self.probe(binaries: binaries, locate: locate, status: status)
        guard !Task.isCancelled else {
            refreshRequested = true
            return
        }
        items = result
    }

    /// Both synchronous PATH lookup and async auth checks run off MainActor.
    @concurrent
    nonisolated private static func probe(
        binaries: [String: String], locate: @escaping Locate, status: @escaping Status
    ) async -> [ProviderStatusItem] {
        await withTaskGroup(of: ProviderStatusItem?.self) { group in
            for provider in AICatalog.providers {
                group.addTask {
                    await ProviderStatusProbe().run(
                        provider: provider,
                        binaryName: binaries[provider.key] ?? provider.bin,
                        locate: locate, status: status
                    )
                }
            }
            var found: [String: ProviderStatusItem] = [:]
            for await item in group {
                if let item { found[item.id] = item }
            }
            return AICatalog.providers.compactMap { found[$0.key] }
        }
    }
}
