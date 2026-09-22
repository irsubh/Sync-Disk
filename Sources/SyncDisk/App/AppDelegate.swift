import SwiftUI
import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {

    private var observers: [Any] = []

    public override init() {
        super.init()
        // Apply dock icon as early as possible during startup
        Self.applyAdaptiveIcon()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Start silently as an accessory or open window if launched directly
        Self.applyAdaptiveIcon()
        observeThemeChanges()
        
        Task { @MainActor in
            WindowManager.shared.openHistoryWindow(syncEngine: SyncEngine.shared)
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            WindowManager.shared.openHistoryWindow(syncEngine: SyncEngine.shared)
        }
        return true
    }

    // MARK: - Adaptive Dock Icon

    /// Determines whether the system or app icon style is in Dark mode.
    /// Checks:
    /// 1. AppleIconAppearanceTheme (macOS Sequoia Dark / Tinted icon theme: e.g. "RegularDark")
    /// 2. AppleInterfaceStyle (system-wide dark mode: "Dark")
    /// 3. NSApp.effectiveAppearance (darkAqua)
    public static var isDarkModeOrDarkIcons: Bool {
        let global = UserDefaults(suiteName: "Apple Global Domain")
        if let iconTheme = global?.string(forKey: "AppleIconAppearanceTheme"),
           iconTheme.localizedCaseInsensitiveContains("dark") {
            return true
        }
        if let style = global?.string(forKey: "AppleInterfaceStyle"),
           style.localizedCaseInsensitiveContains("dark") {
            return true
        }
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return true
        }
        return false
    }

    public static func applyAdaptiveIcon() {
        let isDark = isDarkModeOrDarkIcons
        let iconName = isDark ? "AppIconDark" : "AppIconLight"

        var icon: NSImage?

        // 1. Try bundle resource by name (packaged .app)
        if let rp = Bundle.main.resourcePath {
            // Direct PNG (crisp full-resolution 1024x1024)
            let pngPath = (rp as NSString).appendingPathComponent(iconName + ".png")
            if FileManager.default.fileExists(atPath: pngPath) {
                icon = NSImage(contentsOfFile: pngPath)
            }
            // Try .icns if PNG not found
            if icon == nil {
                let icnsPath = (rp as NSString).appendingPathComponent(iconName + ".icns")
                if FileManager.default.fileExists(atPath: icnsPath) {
                    icon = NSImage(contentsOfFile: icnsPath)
                }
            }
        }

        // 2. NSBundle image lookup (fallback)
        if icon == nil {
            icon = Bundle.main.image(forResource: iconName)
        }

        // 3. Dev-mode: look for dark.png / light.png in project root
        if icon == nil {
            let devFile = isDark ? "dark.png" : "light.png"
            var projectRoot = URL(fileURLWithPath: #file)
            for _ in 0..<4 { projectRoot = projectRoot.deletingLastPathComponent() }
            let devPath = projectRoot.appendingPathComponent(devFile).path
            if FileManager.default.fileExists(atPath: devPath) {
                icon = NSImage(contentsOfFile: devPath)
            }
        }

        // 4. Final fallback: original logo.png
        if icon == nil, let u = Bundle.main.url(forResource: "logo", withExtension: "png") {
            icon = NSImage(contentsOf: u)
        }

        if let icon {
            NSApp.applicationIconImage = icon
        }
    }

    private func observeThemeChanges() {
        let dCenter = DistributedNotificationCenter.default()
        
        // 1. System appearance change (Light / Dark)
        let obs1 = dCenter.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { _ in
            AppDelegate.applyAdaptiveIcon()
        }
        observers.append(obs1)

        // 2. Color & icon appearance preferences change (macOS Sequoia Icon theme changes)
        let obs2 = dCenter.addObserver(
            forName: NSNotification.Name("AppleColorPreferencesChangedNotification"),
            object: nil,
            queue: .main
        ) { _ in
            AppDelegate.applyAdaptiveIcon()
        }
        observers.append(obs2)
    }

    deinit {
        let dCenter = DistributedNotificationCenter.default()
        for obs in observers {
            dCenter.removeObserver(obs)
        }
    }
}
