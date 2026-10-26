import CoreServices
import Foundation

/// Watches one directory for file additions/removals via a DispatchSource
/// (replaces the Python app's polling thread), or a whole tree via FSEvents
/// when `recursive` (source folders: discovery scans nested folders too).
/// Events are debounced and delivered on the main actor.
@MainActor
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var stream: FSEventStreamRef?
    private var debounceTask: Task<Void, Never>?
    /// Recursive mode: changes only under these folders (e.g. an output
    /// folder inside the source folder) never fire.
    private var ignored: [String] = []
    private var watching: [String] = []
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func watch(_ url: URL, recursive: Bool = false, ignoring: [URL] = []) {
        // Every profile save calls this; recreating an identical stream is wasted work.
        let request = [url.standardizedFileURL.path, recursive ? "1" : "0"] + ignoring.map(\.standardizedFileURL.path)
        if request == watching, source != nil || stream != nil { return }
        stop()
        watching = request
        if recursive {
            ignored = ignoring.map { $0.standardizedFileURL.path + "/" }
            watchTree(url)
            return
        }
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
            queue: .main)
        source.setEventHandler { [weak self] in
            self?.changed()
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    private func watchTree(_ url: URL) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let changed = (0..<count).map { String(cString: cPaths[$0]) }
            // The stream is scheduled on the main queue.
            MainActor.assumeIsolated { watcher.treeChanged(changed) }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    private func treeChanged(_ paths: [String]) {
        let relevant = paths.contains { path in
            let folder = path.hasSuffix("/") ? path : path + "/"
            return !ignored.contains { folder.hasPrefix($0) }
        }
        if relevant { changed() }
    }

    private func changed() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.onChange()
        }
    }

    func stop() {
        watching = []
        debounceTask?.cancel()
        source?.cancel()
        source = nil
        descriptor = -1
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit {
        source?.cancel()
        // The stream holds an unretained pointer to self: end it first.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
