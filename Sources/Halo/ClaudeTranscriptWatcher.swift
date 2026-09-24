import CoreServices
import Foundation

/// Watches Claude's local project-transcript tree without polling. File-level
/// event paths let the monitor reread only changed transcripts; directory
/// changes fall back to a bounded session discovery scan.
final class ClaudeTranscriptWatcher {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let onChange: ([String]) -> Void
    private var stream: FSEventStreamRef?
    private var watchedPath: String?

    init(queue: DispatchQueue, onChange: @escaping ([String]) -> Void) {
        self.queue = queue
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        onQueue { stopOnQueue() }
    }

    func start(watching directory: URL) {
        onQueue {
            let path = directory.standardizedFileURL.path
            guard watchedPath != path else { return }
            stopOnQueue()

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                Self.eventCallback,
                &context,
                [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.4,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
            )
            guard let stream else { return }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                return
            }
            self.stream = stream
            watchedPath = path
        }
    }

    func stop() {
        onQueue { stopOnQueue() }
    }

    private func onQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private func stopOnQueue() {
        guard let stream else {
            watchedPath = nil
            return
        }
        self.stream = nil
        watchedPath = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func didObserveChange(paths: [String]) {
        onChange(paths)
    }

    private static let eventCallback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
        guard let info else { return }
        let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        let changedPaths = (0..<count).compactMap { index in
            paths[index].map(String.init(cString:))
        }
        Unmanaged<ClaudeTranscriptWatcher>
            .fromOpaque(info)
            .takeUnretainedValue()
            .didObserveChange(paths: changedPaths)
    }
}
