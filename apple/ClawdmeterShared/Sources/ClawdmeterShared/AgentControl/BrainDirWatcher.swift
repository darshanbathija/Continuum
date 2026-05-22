// Vnode watcher around a brain dir. Mirrors `.git/index` watcher pattern
// in `GitDiffPane` — open the dir fd, attach a `DispatchSourceFileSystemObject`,
// debounce 100ms, fire a closure on any write/extend/delete/rename/link
// event. Owns the descriptor lifecycle: closing the watcher closes the
// underlying fd.
//
// Used by Commit 8's Mac Plan pane + Commit 5's DiskObservationProvider
// to re-parse the brain dir whenever Antigravity writes a new step into
// `implementation_plan.md` or a new annotation arrives.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Watches a directory for filesystem events. The callback fires on the
/// caller's chosen queue (defaults to main) with no arguments; the caller
/// re-parses the dir at that point.
///
/// Lifecycle:
///   1. Init with the dir URL and a debounce interval.
///   2. Call `start(onChange:)` with the callback.
///   3. Optionally call `pause()` / `resume()` (e.g. when the Plan pane
///      isn't visible).
///   4. Call `stop()` or let the watcher deinit — both close the fd.
public final class BrainDirWatcher {
    private let dirURL: URL
    private let debounceInterval: TimeInterval
    private let queue: DispatchQueue
#if canImport(Darwin)
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
#endif
    private var debounceTimer: DispatchSourceTimer?
    private var pendingChange = false

    public init(
        dirURL: URL,
        debounceInterval: TimeInterval = 0.1,
        queue: DispatchQueue = .main
    ) {
        self.dirURL = dirURL
        self.debounceInterval = debounceInterval
        self.queue = queue
    }

    deinit {
        stop()
    }

    /// Starts the watcher. The callback runs on the configured queue.
    /// Returns `true` on success, `false` when the dir can't be opened
    /// (e.g. deleted / permission denied) — caller should re-resolve
    /// the brain URL and try again.
    @discardableResult
    public func start(onChange: @escaping () -> Void) -> Bool {
#if canImport(Darwin)
        stop()

        let fd = open(dirURL.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        self.fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: queue
        )
        // Coalesce bursts of events into a single delayed callback. The
        // 100ms window matches the GitDiffPane pattern — long enough to
        // batch partial writes ("[ ]" → "[x]" + 5 nested step updates)
        // into one re-parse, short enough that the UI still feels live.
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.scheduleDebouncedCallback(onChange: onChange)
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        src.resume()
        self.source = src
        return true
#else
        return false
#endif
    }

    /// Pauses event delivery without closing the fd. Useful when the
    /// containing view goes off-screen — no UI cost while paused.
    public func pause() {
#if canImport(Darwin)
        source?.suspend()
#endif
    }

    /// Resumes a paused watcher.
    public func resume() {
#if canImport(Darwin)
        source?.resume()
#endif
    }

    /// Stops watching and releases the file descriptor. The watcher can
    /// be reused by calling `start` again.
    public func stop() {
        debounceTimer?.cancel()
        debounceTimer = nil
#if canImport(Darwin)
        if let source {
            source.cancel()
            self.source = nil
        }
        // Cancellation handler closes the fd; belt-and-suspenders ensure
        // we don't leak when start failed half-way.
        if fileDescriptor >= 0 && source == nil {
            close(fileDescriptor)
            fileDescriptor = -1
        }
#endif
        pendingChange = false
    }

    /// Schedules a single coalesced `onChange` callback `debounceInterval`
    /// after the most recent event. Repeated events within the window
    /// just reset the timer.
    private func scheduleDebouncedCallback(onChange: @escaping () -> Void) {
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + debounceInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.pendingChange = false
            onChange()
        }
        debounceTimer = timer
        pendingChange = true
        timer.resume()
    }
}
