import SwiftUI
import AppKit

public struct LogoIconView: View {
    public let size: CGFloat

    public init(size: CGFloat = 18) {
        self.size = size
    }

    private func logoImage(forDark: Bool) -> NSImage? {
        let name = forDark ? "AppIconDark" : "AppIconLight"
        // 1. Try bundle resources (packaged .app)
        if let img = Bundle.main.image(forResource: name) { return img }
        // 2. Try explicit file in bundle resources
        if let resPath = Bundle.main.resourcePath {
            let path = (resPath as NSString).appendingPathComponent(name + ".png")
            if let img = NSImage(contentsOfFile: path) { return img }
        }
        // 3. Fallback: use original logo.png from bundle
        if let bundleURL = Bundle.main.url(forResource: "logo", withExtension: "png"),
           let img = NSImage(contentsOf: bundleURL) { return img }
        // 4. Fallback: source workspace (dev mode only)
        let fallback = "/Users/subh/Library/Mobile Documents/com~apple~CloudDocs/code/app/new/Sync Disk/logo.png"
        return NSImage(contentsOfFile: fallback)
    }

    public var body: some View {
        _LogoIconViewAdapter(size: size)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.224, style: .continuous))
    }
}

/// AppKit-backed view to read effective appearance and choose light/dark logo
private struct _LogoIconViewAdapter: NSViewRepresentable {
    let size: CGFloat

    func makeNSView(context: Context) -> _AppearanceAwareImageView {
        _AppearanceAwareImageView(size: size)
    }

    func updateNSView(_ view: _AppearanceAwareImageView, context: Context) {
        view.size = size
        view.updateImage()
    }
}

final class _AppearanceAwareImageView: NSView {
    var size: CGFloat
    private let imageView = NSImageView()

    init(size: CGFloat) {
        self.size = size
        super.init(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = false
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateImage()
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    func updateImage() {
        let isDark = AppDelegate.isDarkModeOrDarkIcons ||
            (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let name = isDark ? "AppIconDark" : "AppIconLight"

        var img: NSImage?
        // 1. Bundle resource (packaged .app has AppIconLight.png / AppIconDark.png)
        if let rp = Bundle.main.resourcePath {
            let p = (rp as NSString).appendingPathComponent(name + ".png")
            if FileManager.default.fileExists(atPath: p) {
                img = NSImage(contentsOfFile: p)
            }
        }
        // 2. NSBundle image lookup
        if img == nil { img = Bundle.main.image(forResource: name) }
        // 3. Dev-mode: light.png / dark.png in project root
        if img == nil {
            let devFile = isDark ? "dark.png" : "light.png"
            var root = URL(fileURLWithPath: #file)
            for _ in 0..<5 { root = root.deletingLastPathComponent() }
            let devPath = root.appendingPathComponent(devFile).path
            if FileManager.default.fileExists(atPath: devPath) {
                img = NSImage(contentsOfFile: devPath)
            }
        }
        // 4. logo.png fallback
        if img == nil, let u = Bundle.main.url(forResource: "logo", withExtension: "png") {
            img = NSImage(contentsOf: u)
        }
        if img == nil {
            let fallback = "/Users/subh/Library/Mobile Documents/com~apple~CloudDocs/code/app/new/Sync Disk/logo.png"
            img = NSImage(contentsOfFile: fallback)
        }
        imageView.image = img
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: size, height: size)
    }
}
