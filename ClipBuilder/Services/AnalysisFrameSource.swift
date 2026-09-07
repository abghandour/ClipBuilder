import Foundation

/// Request-scoped lazy still grid. The dispatch fallback and prompt-size retry
/// share the same immutable result without decoding it on native-video success.
actor AnalysisFrameSource {
    private let loader: @Sendable () async throws -> [AIFrame]
    private var cached: [AIFrame]?

    init(loader: @escaping @Sendable () async throws -> [AIFrame]) {
        self.loader = loader
    }

    func frames() async throws -> [AIFrame] {
        try Task.checkCancellation()
        if let cached { return cached }
        let frames = try await loader()
        try Task.checkCancellation()
        cached = frames
        return frames
    }
}
