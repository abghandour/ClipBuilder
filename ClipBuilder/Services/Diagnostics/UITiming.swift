import AppKit
import BugReporterKit
import OSLog

/// Click-to-response timing for the screens people complain about, written
/// to the rolling log so a bug report from the field says how long a click
/// took, not just that it "felt slow". Also emits signposts for Instruments.
@MainActor
enum UITiming {
    private static let log = Logger(subsystem: "com.mokotti-solutions.clipbuilder", category: "timing")
    private static var monitor: Any?
    /// Uptime of the last primary mouse-down anywhere in the app.
    private(set) static var lastMouseDown: TimeInterval?
    /// Uptime of the last selection change reported through `selectionChanged`.
    private(set) static var lastSelectionChange: TimeInterval?
    private static var selectionInterval: PerfSignpost.Interval?

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// One local event monitor for the process; harmless to call twice.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            lastMouseDown = uptime
            return event
        }
    }

    /// Milliseconds between now and the last mouse-down, or nil when no click
    /// happened recently enough to be the cause (keyboard navigation, restore).
    static func millisecondsSinceMouseDown(window: TimeInterval = 5) -> Int? {
        guard let lastMouseDown else { return nil }
        let elapsed = uptime - lastMouseDown
        return elapsed <= window ? Int(elapsed * 1000) : nil
    }

    /// Call from a selection `onChange`. Logs the click-to-selection latency
    /// and opens a signpost that `responseReady` closes.
    static func selectionChanged(screen: String, count: Int) {
        lastSelectionChange = uptime
        PerfSignpost.end(selectionInterval)
        selectionInterval = PerfSignpost.begin("ui.selection", metadata: screen)
        let latency = millisecondsSinceMouseDown().map { "\($0) ms after mouse down" } ?? "no recent click"
        emit("\(screen) selection → \(count) item\(count == 1 ? "" : "s"), \(latency)")
    }

    /// Call when the thing the selection drives (a preview, a pane) is ready.
    static func responseReady(screen: String, what: String) {
        PerfSignpost.end(selectionInterval)
        selectionInterval = nil
        guard let lastSelectionChange else { return }
        let elapsed = Int((uptime - lastSelectionChange) * 1000)
        emit("\(screen) \(what) ready \(elapsed) ms after selection")
    }

    private static func emit(_ line: String) {
        log.debug("\(line, privacy: .public)")
        BugReporter.log("timing", line)
    }
}
