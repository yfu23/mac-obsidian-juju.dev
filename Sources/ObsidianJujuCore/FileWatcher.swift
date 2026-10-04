import CoreServices
import Foundation

/// Watches a folder tree with FSEvents and calls `onChange` (on the main queue) after changes
/// settle. Used to keep the index and open notes live while you edit in Obsidian.
public final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    public init?(root: URL, latency: TimeInterval = 0.4, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot))
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
