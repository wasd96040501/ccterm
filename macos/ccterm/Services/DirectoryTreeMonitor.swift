import Foundation

final class DirectoryTreeMonitor {

    // MARK: - Types

    enum Event {
        case fileCreated(URL)
        case fileRemoved(URL)
        case fileModified(URL)
        case directoryCreated(URL)
        case directoryRemoved(URL)
    }

    // MARK: - Properties

    private let directory: URL
    private let latency: TimeInterval
    private let onChange: ([Event]) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.ccterm.directorytreemonitor", qos: .utility)

    // MARK: - Lifecycle

    init(directory: URL, latency: TimeInterval = 1.0, onChange: @escaping ([Event]) -> Void) {
        self.directory = directory
        self.latency = latency
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    func start() {
        stop()

        let pathsToWatch = [directory.path] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        guard let stream = FSEventStreamCreate(
            nil,
            DirectoryTreeMonitor.callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            UInt32(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagNoDefer
            )
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - Private Methods

    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
        guard let info else { return }
        let monitor = Unmanaged<DirectoryTreeMonitor>.fromOpaque(info).takeUnretainedValue()

        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
        let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))

        var events: [Event] = []
        for i in 0..<numEvents {
            let url = URL(fileURLWithPath: paths[i])
            let flag = flags[i]
            let isDir = (flag & UInt32(kFSEventStreamEventFlagItemIsDir)) != 0
            let isFile = (flag & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0
            let created = (flag & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
            let removed = (flag & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
            let modified = (flag & UInt32(kFSEventStreamEventFlagItemModified)) != 0
            let renamed = (flag & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0

            if isDir {
                if removed || (renamed && !FileManager.default.fileExists(atPath: paths[i])) {
                    events.append(.directoryRemoved(url))
                } else if created || (renamed && FileManager.default.fileExists(atPath: paths[i])) {
                    events.append(.directoryCreated(url))
                }
            } else if isFile {
                if removed || (renamed && !FileManager.default.fileExists(atPath: paths[i])) {
                    events.append(.fileRemoved(url))
                } else if created || (renamed && FileManager.default.fileExists(atPath: paths[i])) {
                    events.append(.fileCreated(url))
                } else if modified {
                    events.append(.fileModified(url))
                }
            }
        }

        if !events.isEmpty {
            monitor.onChange(events)
        }
    }
}
