import SwiftUI
import QuickLookUI

public struct QuickLookPreview: NSViewRepresentable {
    public let previewURL: URL?
    
    public init(previewURL: URL?) {
        self.previewURL = previewURL
    }
    
    public func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = false
        if let url = previewURL {
            view.previewItem = url as QLPreviewItem
        }
        return view
    }
    
    public func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if let url = previewURL {
            nsView.previewItem = url as QLPreviewItem
        } else {
            nsView.previewItem = nil
        }
    }
}
