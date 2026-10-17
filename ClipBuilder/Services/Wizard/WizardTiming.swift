import Foundation

/// Stage timings for a reel render, carried on the ordinary emit stream as
/// `TIMING:<stage>=<seconds>` lines. The engine emits them; Express folds them
/// into one summary per reel, the full wizard shows them as log lines, and the
/// performance baseline reads them from the app's stdout.
nonisolated enum WizardTiming {
    static let prefix = "TIMING:"

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func line(_ stage: String, seconds: Double) -> String {
        "\(prefix)\(stage)=\(String(format: "%.3f", max(0, seconds)))"
    }

    static func line(_ stage: String, _ duration: Duration) -> String {
        line(stage, seconds: seconds(duration))
    }

    /// Nil for any line that is not a timing line.
    static func parse(_ line: String) -> (stage: String, seconds: Double)? {
        guard line.hasPrefix(prefix) else { return nil }
        let body = line.dropFirst(prefix.count)
        guard let equals = body.lastIndex(of: "=") else { return nil }
        let stage = String(body[..<equals]).trimmingCharacters(in: .whitespaces)
        guard !stage.isEmpty, let seconds = Double(body[body.index(after: equals)...]) else { return nil }
        return (stage, seconds)
    }

    /// "12.3s", "1m 05s".
    static func format(_ seconds: Double) -> String {
        let value = max(0, seconds)
        if value < 60 { return String(format: "%.1fs", value) }
        let minutes = Int(value) / 60
        let rest = Int(value.rounded()) % 60
        return String(format: "%dm %02ds", minutes, rest)
    }

    /// The readable form of a timing line for plain logs: "⏱ extract clips 12.3s".
    static func display(_ line: String) -> String? {
        parse(line).map { "⏱ \($0.stage) \(format($0.seconds))" }
    }

    /// Time `body` and report it as a timing line through `emit`. Errors and
    /// cancellation still report the time spent before propagating. Stages
    /// that usually have nothing to do pass `minimumSeconds` so a skipped
    /// step does not clutter the summary.
    static func measure<T>(_ stage: String, emit: @Sendable (String) -> Void, minimumSeconds: Double = 0,
                           isolation: isolated (any Actor)? = #isolation,
                           _ body: () async throws -> T) async rethrows -> T {
        let started = ContinuousClock.now
        let interval = PerfSignpost.begin("WizardStage", metadata: stage)
        defer {
            PerfSignpost.end(interval)
            let elapsed = started.duration(to: .now)
            if seconds(elapsed) >= minimumSeconds { emit(line(stage, elapsed)) }
        }
        return try await body()
    }

    /// Timings gathered from several reels, grouped the way the user sees the
    /// work ("Reel 1 of 3"). Stages that repeat within a group add up.
    final class Collector: @unchecked Sendable {
        struct Entry: Equatable, Sendable {
            var stage: String
            var seconds: Double
        }

        private let lock = NSLock()
        private var groups: [(name: String, entries: [Entry])] = []

        init() {}

        /// Returns false for lines that are not timing lines, so callers can
        /// fall through to ordinary logging.
        @discardableResult
        func record(_ line: String, group: String) -> Bool {
            guard let parsed = WizardTiming.parse(line) else { return false }
            record(stage: parsed.stage, seconds: parsed.seconds, group: group)
            return true
        }

        func record(stage: String, seconds: Double, group: String) {
            lock.lock()
            defer { lock.unlock() }
            if let index = groups.firstIndex(where: { $0.name == group }) {
                if let existing = groups[index].entries.firstIndex(where: { $0.stage == stage }) {
                    groups[index].entries[existing].seconds += seconds
                } else {
                    groups[index].entries.append(Entry(stage: stage, seconds: seconds))
                }
            } else {
                groups.append((group, [Entry(stage: stage, seconds: seconds)]))
            }
        }

        func entries(group: String) -> [Entry] {
            lock.lock()
            defer { lock.unlock() }
            return groups.first { $0.name == group }?.entries ?? []
        }

        var groupNames: [String] {
            lock.lock()
            defer { lock.unlock() }
            return groups.map(\.name)
        }

        /// One line per group, stages in the order they finished:
        /// "Timings · Reel 1 of 3: extract clips 20.1s · compositor 15.0s · caption 6.1s".
        func summaryLines(total: Double? = nil) -> [String] {
            let snapshot: [(name: String, entries: [Entry])] = {
                lock.lock()
                defer { lock.unlock() }
                return groups
            }()
            var lines = snapshot.map { group in
                "Timings · \(group.name): " + group.entries
                    .map { "\($0.stage) \(WizardTiming.format($0.seconds))" }
                    .joined(separator: " · ")
            }
            if let total { lines.append("Timings · total \(WizardTiming.format(total)) from Generate to results") }
            return lines
        }
    }
}
