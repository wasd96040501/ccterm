import Foundation

final class FileMonitorService {

    // MARK: - Properties

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?
    private let queue: DispatchQueue
    private let debounceInterval: TimeInterval
    private let onChange: () -> Void

    // MARK: - Lifecycle

    init(
        debounceInterval: TimeInterval = 0.3,
        queue: DispatchQueue = .init(label: "com.ccterm.filemonitor", qos: .utility),
        onChange: @escaping () -> Void
    ) {
        self.debounceInterval = debounceInterval
        self.queue = queue
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    func start(url: URL) {
        stop()

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.stop()
                return
            }
            self.scheduleDebounce()
        }

        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        self.source = src
        src.resume()
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let source {
            source.cancel()
            self.source = nil
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    // MARK: - Private Methods

    private func scheduleDebounce() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
