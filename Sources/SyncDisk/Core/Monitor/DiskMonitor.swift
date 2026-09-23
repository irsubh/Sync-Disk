import Foundation
import AppKit

public final class DiskMonitor: @unchecked Sendable {
    public typealias StatusChangeHandler = (Bool) -> Void
    
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.syncdisk.diskmonitor", qos: .utility)
    private var observers: [NSObjectProtocol] = []
    public private(set) var isRunning: Bool = false
    
    public var destinationURL: URL? {
        didSet {
            checkStatus(forceNotify: true)
        }
    }
    
    public private(set) var isConnected: Bool = false
    public var onStatusChange: StatusChangeHandler?
    public var onPeriodicCheck: (() -> Void)?
    
    public init(destinationURL: URL? = nil, autoStart: Bool = true) {
        self.destinationURL = destinationURL
        setupNotifications()
        if autoStart {
            start()
        }
    }
    
    deinit {
        stop()
    }
    
    public func start() {
        guard !isRunning else {
            checkStatus(forceNotify: true)
            return
        }
        isRunning = true
        startTimer()
        checkStatus(forceNotify: true)
    }
    
    public func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
        onStatusChange = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
    
    private func setupNotifications() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        
        let mountObs = wsCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkStatus(forceNotify: true)
        }
        
        let unmountObs = wsCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkStatus(forceNotify: true)
        }
        
        observers = [mountObs, unmountObs]
    }
    
    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5.0, repeating: 5.0)
        t.setEventHandler { [weak self] in
            self?.checkStatus(forceNotify: false)
            self?.onPeriodicCheck?()
        }
        self.timer = t
        t.resume()
    }
    
    public func checkStatus(forceNotify: Bool = false) {
        guard let url = destinationURL else {
            updateConnected(false, forceNotify: forceNotify)
            return
        }
        
        let path = url.standardizedFileURL.path
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let isWritable = exists && FileManager.default.isWritableFile(atPath: path)
        let connected = exists && isWritable
        
        updateConnected(connected, forceNotify: forceNotify)
    }
    
    private func updateConnected(_ newStatus: Bool, forceNotify: Bool) {
        if newStatus != isConnected || forceNotify {
            isConnected = newStatus
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onStatusChange?(newStatus)
            }
        }
    }
}
