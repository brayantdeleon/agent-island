import Darwin
import Foundation

/// Watches the directory containing Codex's session-name index.
///
/// Watching the directory instead of the file survives Codex replacing
/// `session_index.jsonl` atomically during a rename.
final class CodexSessionIndexWatcher: @unchecked Sendable {
    private let directoryURL: URL
    private let debounceInterval: TimeInterval
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var pendingChange: DispatchWorkItem?

    init(
        sessionIndexURL: URL,
        debounceInterval: TimeInterval = 0.15,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.directoryURL = sessionIndexURL.deletingLastPathComponent()
        self.debounceInterval = debounceInterval
        self.queue = DispatchQueue(label: "app.openisland.codex-session-index-watcher")
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        queue.sync {
            guard source == nil else { return }

            let descriptor = open(directoryURL.path, O_EVTONLY)
            guard descriptor >= 0 else { return }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleChange()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            self.source = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            pendingChange?.cancel()
            pendingChange = nil
            source?.cancel()
            source = nil
        }
    }

    private func scheduleChange() {
        pendingChange?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        pendingChange = workItem
        queue.asyncAfter(
            deadline: .now() + debounceInterval,
            execute: workItem
        )
    }
}
