import SwiftUI
import AppKit

@MainActor
public final class WindowManager: NSObject, ObservableObject, NSWindowDelegate {
    public static let shared = WindowManager()
    
    private var historyWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    
    public override init() {
        super.init()
    }
    
    public func openHistoryWindow(syncEngine: SyncEngine, initialMode: HistoryViewMode = .files) {
        NSApplication.shared.setActivationPolicy(.regular)
        AppDelegate.applyAdaptiveIcon()
        syncEngine.activeViewMode = initialMode
        
        if let window = historyWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        
        let contentView = HistoryWindowView(syncEngine: syncEngine)
        let hostingController = NSHostingController(rootView: contentView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1200, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Sync Disk"
        window.minSize = NSSize(width: 960, height: 580)
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.center()
        
        self.historyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    
    public func openStorageWindow(syncEngine: SyncEngine) {
        openHistoryWindow(syncEngine: syncEngine, initialMode: .storage)
    }
    
    public func openSettingsWindow(syncEngine: SyncEngine) {
        // In-app Settings: Open main window with settings sheet presented
        syncEngine.showSettingsSheet = true
        openHistoryWindow(syncEngine: syncEngine)
    }
    
    public func openOnboardingWindow(syncEngine: SyncEngine) {
        NSApplication.shared.setActivationPolicy(.regular)
        AppDelegate.applyAdaptiveIcon()
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        
        let contentView = OnboardingWindowView(syncEngine: syncEngine) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        let hostingController = NSHostingController(rootView: contentView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 150, y: 150, width: 520, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Welcome to Sync Disk"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.center()
        
        self.onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    
    // MARK: - NSWindowDelegate
    
    public func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }
        
        if closedWindow == historyWindow {
            // Dismiss in-app sheet if open
            SyncEngine.shared.showSettingsSheet = false
            // Switch activation policy to .accessory: removes app from Dock and hides running dot,
            // while keeping the menu bar extra and background sync running seamlessly.
            NSApplication.shared.setActivationPolicy(.accessory)
        } else if closedWindow == onboardingWindow {
            if historyWindow == nil || !historyWindow!.isVisible {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }
    
    public func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == historyWindow else { return }
        if let contentView = window.contentView {
            for sv in findAllSplitViews(in: contentView) {
                if sv.subviews.count == 3 {
                    sv.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
                    sv.setHoldingPriority(NSLayoutConstraint.Priority(50), forSubviewAt: 1)
                    sv.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 2)
                }
            }
        }
    }
    
    private func findAllSplitViews(in view: NSView) -> [NSSplitView] {
        var result: [NSSplitView] = []
        if let sv = view as? NSSplitView {
            result.append(sv)
        }
        for sub in view.subviews {
            result.append(contentsOf: findAllSplitViews(in: sub))
        }
        return result
    }
}
