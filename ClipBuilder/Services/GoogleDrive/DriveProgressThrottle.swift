import Foundation

/// Drop intermediate chunk notifications before hopping to the UI actor.
/// Completion is published by the job itself, so even fast jobs finish at 100%.
actor DriveProgressThrottle {
    private var last: TimeInterval?
    private let now: @Sendable () -> TimeInterval

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func acceptsUpdate() -> Bool {
        let time = now()
        guard last == nil || time - last! >= 0.25 else { return false }
        last = time
        return true
    }
}
