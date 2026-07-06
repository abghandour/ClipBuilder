import Foundation

/// Watches one directory for file additions/removals via a DispatchSource
/// (replaces the Python app's polling thread). Events are debounced and
/// delivered on the main actor.
@MainActor
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var debounceTask: Task<Void, Never>?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func watch(_ url: URL) {
        stop()
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
            queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.debounceTask?.cancel()
            self.debounceTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.onChange()
            }
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        debounceTask?.cancel()
        source?.cancel()
        source = nil
        descriptor = -1
    }

    deinit {
        source?.cancel()
    }
}
