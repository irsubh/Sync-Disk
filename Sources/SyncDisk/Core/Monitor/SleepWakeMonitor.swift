import Foundation
import AppKit

public final class SleepWakeMonitor: @unchecked Sendable {
    private var observers: [NSObjectProtocol] = []
    
    public var onSleep: (() -> Void)?
    public var onWake: (() -> Void)?
    
    public init() {
        setupObservers()
    }
    
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    
    private func setupObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        
        let sleepObs = wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onSleep?()
        }
        
        let wakeObs = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onWake?()
        }
        
        observers = [sleepObs, wakeObs]
    }
}
