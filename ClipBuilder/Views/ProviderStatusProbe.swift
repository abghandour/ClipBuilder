import Foundation

/// Bounds the whole lookup/status probe, including a slow login-shell PATH
/// lookup. A timed-out installed provider remains visible with unknown status.
actor ProviderStatusProbe {
    private var continuation: CheckedContinuation<ProviderStatusItem?, Never>?
    private var worker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var fallback: ProviderStatusItem?
    private var finished = false

    func run(
        provider: AICatalog.Provider,
        binaryName: String,
        locate: @escaping @Sendable (String) -> URL?,
        status: @escaping @Sendable (String, URL) async -> ProviderAuth.State
    ) async -> ProviderStatusItem? {
        guard !Task.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                worker = Task.detached(priority: .utility) {
                    guard let binary = locate(binaryName) else {
                        await self.finish(nil)
                        return
                    }
                    let unknown = ProviderStatusItem(id: provider.key, label: provider.label, state: .unknown)
                    guard await self.didLocate(unknown), !Task.isCancelled else { return }
                    let state = await status(provider.key, binary)
                    await self.finish(ProviderStatusItem(id: provider.key, label: provider.label, state: state))
                }
                deadline = Task {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    finish(fallback)
                }
            }
        } onCancel: {
            Task { await self.finish(nil) }
        }
    }

    private func didLocate(_ item: ProviderStatusItem) -> Bool {
        guard !finished else { return false }
        fallback = item
        return true
    }

    private func finish(_ item: ProviderStatusItem?) {
        guard !finished else { return }
        finished = true
        worker?.cancel()
        deadline?.cancel()
        worker = nil
        deadline = nil
        continuation?.resume(returning: item)
        continuation = nil
    }
}
