import Foundation

/// Last successful subscription check for this launch and API key. A failed
/// refresh leaves that snapshot intact; callers can hide it for their own UI.
actor ElevenLabsSubscriptionCache {
    static let shared = ElevenLabsSubscriptionCache()

    private let key: @Sendable () throws -> String?
    private let client: @Sendable (String) -> ElevenLabsClient
    private var cachedKey: String?
    private var subscription: ElevenLabsSubscription?

    init(key: @escaping @Sendable () throws -> String? = { try ElevenLabsKeychain().read() },
         client: @escaping @Sendable (String) -> ElevenLabsClient = { ElevenLabsClient(apiKey: $0) }) {
        self.key = key
        self.client = client
    }

    func lastSuccessful() -> ElevenLabsSubscription? {
        guard let currentKey = try? key(), !currentKey.isEmpty, currentKey == cachedKey else {
            cachedKey = nil
            subscription = nil
            return nil
        }
        return subscription
    }

    @discardableResult
    func refresh() async throws -> ElevenLabsSubscription {
        // Discard a previous account's balance even when this request fails.
        _ = lastSuccessful()
        guard let currentKey = try key(), !currentKey.isEmpty else { throw ElevenLabsError.invalidKey }
        let result = try await client(currentKey).subscription()
        try Task.checkCancellation()
        guard try key() == currentKey else { throw CancellationError() }
        cachedKey = currentKey
        subscription = result
        return result
    }
}
