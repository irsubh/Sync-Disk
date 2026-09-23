import Foundation
import CoreServices

public final class FSEventsMonitor: @unchecked Sendable {
    public typealias ChangeHandler = ([URL]) -> Void
    
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.syncdisk.fsevents", qos: .utility)
    private var debounceTimer: DispatchSourceTimer?
    private var pendingURLs: Set<URL> = []
    private let pendingLock = NSLock()
    
    public var pathsToWatch: [String] = []
    public var excludedPathPrefixes: [String] = []
    public var debounceInterval: TimeInterval = 1.0
    public var onChange: ChangeHandler?
    
    public init() {}
    
    deinit {
        stop()
    }
    
    public func isPathExcluded(_ path: String) -> Bool {
        if path.contains("/.backup") || path.contains("/.staging_") {
            return true
        }
        for prefix in excludedPathPrefixes {
            if path.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }
    
    public func start(
        paths: [String],
        excludedPrefixes: [String] = [],
        debounce: TimeInterval = 1.0,
        onChange: @escaping ChangeHandler
    ) {
        stop()
        self.pathsToWatch = paths.filter { FileManager.default.fileExists(atPath: $0) }
        self.excludedPathPrefixes = excludedPrefixes
        self.debounceInterval = debounce
        self.onChange = onChange
        
        guard !pathsToWatch.isEmpty else { return }
        
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        let cfPaths = pathsToWatch as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )
        
        let callback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let info = clientCallBackInfo else { return }
            let monitor = Unmanaged<FSEventsMonitor>.fromOpaque(info).takeUnretainedValue()
            
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            
            var urls: [URL] = []
            for path in paths {
                let name = (path as NSString).lastPathComponent
                if name.hasPrefix(".") || name == ".DS_Store" || name == ".localized" {
                    continue
                }
                if monitor.isPathExcluded(path) {
                    continue
                }
                urls.append(URL(fileURLWithPath: path))
            }
            
            monitor.handleEvents(urls: urls)
        }
        
        guard let streamRef = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(flags)
        ) else {
            return
        }
        
        self.stream = streamRef
        FSEventStreamSetDispatchQueue(streamRef, queue)
        FSEventStreamStart(streamRef)
    }
    
    public func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        cancelDebounceTimer()
        pendingLock.lock()
        pendingURLs.removeAll()
        pendingLock.unlock()
    }
    
    private func handleEvents(urls: [URL]) {
        guard !urls.isEmpty else { return }
        
        pendingLock.lock()
        urls.forEach { pendingURLs.insert($0) }
        pendingLock.unlock()
        
        scheduleDebouncedFlush()
    }
    
    private func scheduleDebouncedFlush() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.cancelDebounceTimer()
            
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.debounceInterval)
            timer.setEventHandler { [weak self] in
                self?.flushPendingEvents()
            }
            self.debounceTimer = timer
            timer.resume()
        }
    }
    
    private func cancelDebounceTimer() {
        debounceTimer?.cancel()
        debounceTimer = nil
    }
    
    private func flushPendingEvents() {
        pendingLock.lock()
        let batch = Array(pendingURLs)
        pendingURLs.removeAll()
        pendingLock.unlock()
        
        cancelDebounceTimer()
        
        guard !batch.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(batch)
        }
    }
}
