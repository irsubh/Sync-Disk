import SwiftUI
import AppKit

/// Provides the menu bar status item icon.
/// Loads the monochrome template icon derived directly from the user's logo emblem.
/// Since it is marked as a template (isTemplate = true), macOS automatically renders
/// it correctly for light and dark menu bars, full-screen spaces, and accented states.
public final class MenuBarIconProvider {
    public static let shared = MenuBarIconProvider()
    private var cachedIcon: NSImage?
    
    public init() {}
    
    public func icon() -> NSImage {
        if let cached = cachedIcon { return cached }
        let img = loadTemplateIcon()
        cachedIcon = img
        return img
    }
    
    private func loadTemplateIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        
        // 1. Packaged .app Resources lookup
        if let resPath = Bundle.main.resourcePath {
            let path2x = (resPath as NSString).appendingPathComponent("menu_bar_icon@2x.png")
            let path1x = (resPath as NSString).appendingPathComponent("menu_bar_icon.png")
            
            if FileManager.default.fileExists(atPath: path2x),
               let data2x = try? Data(contentsOf: URL(fileURLWithPath: path2x)),
               let rep2x = NSBitmapImageRep(data: data2x) {
                let img = NSImage(size: size)
                rep2x.size = size
                img.addRepresentation(rep2x)
                if FileManager.default.fileExists(atPath: path1x),
                   let data1x = try? Data(contentsOf: URL(fileURLWithPath: path1x)),
                   let rep1x = NSBitmapImageRep(data: data1x) {
                    rep1x.size = size
                    img.addRepresentation(rep1x)
                }
                img.isTemplate = true
                return img
            }
        }
        
        // 2. Direct named lookup from Bundle
        if let bundleImg = Bundle.main.image(forResource: "menu_bar_icon") {
            bundleImg.size = size
            bundleImg.isTemplate = true
            return bundleImg
        }
        
        // 3. Fallback to .build/menu_bar_icons during development
        var projRoot = URL(fileURLWithPath: #file)
        for _ in 0..<5 { projRoot = projRoot.deletingLastPathComponent() }
        let devBuildPath = projRoot.appendingPathComponent(".build/menu_bar_icons").path
        let dev2x = (devBuildPath as NSString).appendingPathComponent("menu_bar_icon@2x.png")
        let dev1x = (devBuildPath as NSString).appendingPathComponent("menu_bar_icon.png")
        
        if FileManager.default.fileExists(atPath: dev2x),
           let data2x = try? Data(contentsOf: URL(fileURLWithPath: dev2x)),
           let rep2x = NSBitmapImageRep(data: data2x) {
            let devImg = NSImage(size: size)
            rep2x.size = size
            devImg.addRepresentation(rep2x)
            if FileManager.default.fileExists(atPath: dev1x),
               let data1x = try? Data(contentsOf: URL(fileURLWithPath: dev1x)),
               let rep1x = NSBitmapImageRep(data: data1x) {
                rep1x.size = size
                devImg.addRepresentation(rep1x)
            }
            devImg.isTemplate = true
            return devImg
        }
        
        // 4. Safe fallback: SF Symbol
        let fallback = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Sync Disk") ?? NSImage()
        fallback.size = size
        fallback.isTemplate = true
        return fallback
    }
}
