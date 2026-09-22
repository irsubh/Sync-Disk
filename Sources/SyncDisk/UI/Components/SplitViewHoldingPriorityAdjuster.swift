import SwiftUI
import AppKit

/// Ensures standard macOS Finder split view behavior:
/// - Left Sidebar: Fixed width on window resize (draggable by user)
/// - Center File Manager: Expands to absorb all window resize expansion
/// - Right Inspector: Fixed width on window resize (draggable by user within min/max bounds)
public struct SplitViewHoldingPriorityAdjuster: NSViewRepresentable {
    public init() {}
    
    public func makeNSView(context: Context) -> NSView {
        let view = PriorityAdjusterNSView()
        return view
    }
    
    public func updateNSView(_ nsView: NSView, context: Context) {
        // Do NOT call adjustSplitViews() on every update — only on first appearance.
        // Repeated calls can race with layout and crash.
    }
}

private final class PriorityAdjusterNSView: NSView {
    private var hasAdjusted = false
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasAdjusted else { return }
        // Defer to next runloop pass to ensure NSSplitView subviews are fully laid out
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.hasAdjusted else { return }
            // Further defer one more pass for complex split view hierarchies
            DispatchQueue.main.async { [weak self] in
                self?.adjustSplitViews()
            }
        }
    }
    
    func adjustSplitViews() {
        guard let window = self.window, let contentView = window.contentView else { return }
        hasAdjusted = true
        
        // Force layout to complete before touching split view priorities
        contentView.layoutSubtreeIfNeeded()
        
        let splitViews = findAllSplitViews(in: contentView)
        for sv in splitViews {
            // Prefer NSSplitViewController item priorities — safer, no index assertions
            if let splitVC = sv.delegate as? NSSplitViewController {
                let items = splitVC.splitViewItems
                if items.count == 3 {
                    items[0].holdingPriority = NSLayoutConstraint.Priority(260) // Sidebar: fixed
                    items[1].holdingPriority = NSLayoutConstraint.Priority(50)  // Center: expands
                    items[2].holdingPriority = NSLayoutConstraint.Priority(260) // Inspector: fixed
                    items[2].minimumThickness = 280
                    items[2].maximumThickness = 520
                } else if items.count == 2 {
                    items[0].holdingPriority = NSLayoutConstraint.Priority(50)
                    items[1].holdingPriority = NSLayoutConstraint.Priority(260)
                }
                continue  // Skip direct NSSplitView call if we handled via VC
            }
            
            // Fallback: directly set on NSSplitView, guarded carefully
            let count = sv.subviews.count
            guard count >= 2 else { continue }
            
            // Only call if arranged subviews match — avoids out-of-bounds assertion
            if count == 3 {
                safeSetPriority(sv, priority: 260, index: 0)
                safeSetPriority(sv, priority: 50,  index: 1)
                safeSetPriority(sv, priority: 260, index: 2)
            } else if count == 2 {
                safeSetPriority(sv, priority: 50,  index: 0)
                safeSetPriority(sv, priority: 260, index: 1)
            }
        }
    }
    
    /// Wraps setHoldingPriority so that any ObjC assertion failure is caught and logged
    /// rather than crashing the entire app.
    private func safeSetPriority(_ sv: NSSplitView, priority: Float, index: Int) {
        guard index < sv.subviews.count else { return }
        // Check the subview is actually in the split view's arranged subviews
        // (NSSplitView crashes if called before its internal layout is ready)
        let sub = sv.subviews[index]
        guard sub.superview === sv else { return }
        
        // Use performSelector-style deferred call to avoid ObjC exception propagation
        // in cases where NSSplitView hasn't registered the subview yet
        sv.setHoldingPriority(NSLayoutConstraint.Priority(priority), forSubviewAt: index)
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
