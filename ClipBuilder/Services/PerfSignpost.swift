import Foundation
import os.signpost

/// Instruments-only stage intervals. Disabled calls do not construct metadata,
/// allocate an interval ID, read a clock, or write to the application's log.
nonisolated enum PerfSignpost {
    private static let log = OSLog(subsystem: "com.mokotti-solutions.clipbuilder", category: .pointsOfInterest)
    static var isEnabled: Bool { log.signpostsEnabled }

    struct Interval: Sendable {
        let name: StaticString
        let id: OSSignpostID
    }

    static func begin(_ name: StaticString, metadata: @autoclosure () -> String = "") -> Interval? {
        guard isEnabled else { return nil }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id, "%{public}@", metadata())
        return Interval(name: name, id: id)
    }

    static func end(_ interval: Interval?) {
        guard let interval else { return }
        os_signpost(.end, log: log, name: interval.name, signpostID: interval.id)
    }

    static func event(_ name: StaticString, metadata: @autoclosure () -> String = "") {
        guard isEnabled else { return }
        os_signpost(.event, log: log, name: name, "%{public}@", metadata())
    }
}
