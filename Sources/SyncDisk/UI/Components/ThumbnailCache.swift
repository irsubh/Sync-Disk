import Foundation
import AppKit
import ImageIO
import QuickLookThumbnailing

/// High-performance memory-cached thumbnail and dimension manager.
/// Uses ImageIO downsampling and QuickLook thumbnailing without decoding full image bitmaps into memory.
public final class ThumbnailCache: @unchecked Sendable {
    public static let shared = ThumbnailCache()
    
    private let imageCache = NSCache<NSString, NSImage>()
    private let dimensionCache = NSCache<NSString, NSString>()
    private let queue = DispatchQueue(label: "com.syncdisk.thumbnailcache", qos: .userInitiated, attributes: .concurrent)
    
    public init() {
        imageCache.countLimit = 500
        imageCache.totalCostLimit = 64 * 1024 * 1024 // 64 MB max thumbnail cache
        dimensionCache.countLimit = 2000
    }
    
    public func cachedThumbnail(for path: String) -> NSImage? {
        return imageCache.object(forKey: path as NSString)
    }
    
    public func cachedDimensions(for path: String) -> String? {
        return dimensionCache.object(forKey: path as NSString) as String?
    }
    
    public func loadThumbnail(
        for fileURL: URL,
        cacheKey: String,
        maxPixelSize: CGFloat = 128
    ) async -> (NSImage?, String?) {
        // Fast path: synchronous cache hit
        if let cachedImg = imageCache.object(forKey: cacheKey as NSString) {
            let cachedDims = dimensionCache.object(forKey: cacheKey as NSString) as String?
            return (cachedImg, cachedDims)
        }
        
        return await withCheckedContinuation { continuation in
            loadThumbnailAndDimensions(for: fileURL, cacheKey: cacheKey, maxPixelSize: maxPixelSize) { img, dims in
                continuation.resume(returning: (img, dims))
            }
        }
    }
    
    public func loadThumbnailAndDimensions(
        for fileURL: URL,
        cacheKey: String,
        maxPixelSize: CGFloat = 128,
        completion: @escaping @MainActor @Sendable (NSImage?, String?) -> Void
    ) {
        // Fast path: synchronous cache hit
        let cachedImg = imageCache.object(forKey: cacheKey as NSString)
        let cachedDims = dimensionCache.object(forKey: cacheKey as NSString) as String?
        if let cachedImg = cachedImg {
            DispatchQueue.main.async {
                completion(cachedImg, cachedDims)
            }
            return
        }
        
        queue.async {
            var extractedDims = cachedDims
            var generatedImage: NSImage? = nil
            
            let ext = fileURL.pathExtension.lowercased()
            let isApp = ext == "app" || (try? fileURL.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
            
            if isApp {
                let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
                icon.size = NSSize(width: maxPixelSize, height: maxPixelSize)
                self.imageCache.setObject(icon, forKey: cacheKey as NSString)
                self.dimensionCache.setObject("Application" as NSString, forKey: cacheKey as NSString)
                DispatchQueue.main.async {
                    completion(icon, "Application")
                }
                return
            }
            
            let isRasterImage = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "bmp", "icns", "ico"].contains(ext)
            
            if isRasterImage {
                // 1. Fast header-only dimensions extraction using ImageIO
                if let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) {
                    if extractedDims == nil, let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
                        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
                        if w > 0 && h > 0 {
                            let nf = NumberFormatter()
                            nf.numberStyle = .decimal
                            let wStr = nf.string(from: NSNumber(value: w)) ?? "\(w)"
                            let hStr = nf.string(from: NSNumber(value: h)) ?? "\(h)"
                            let dimsStr = "\(wStr) × \(hStr)"
                            extractedDims = dimsStr
                            self.dimensionCache.setObject(dimsStr as NSString, forKey: cacheKey as NSString)
                        }
                    }
                    
                    // 2. Hardware-accelerated thumbnail generation (downsamples during decode, zero memory spike)
                    let thumbOptions: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                    ]
                    if let cgThumb = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbOptions as CFDictionary) {
                        let nsThumb = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
                        generatedImage = nsThumb
                        self.imageCache.setObject(nsThumb, forKey: cacheKey as NSString, cost: cgThumb.bytesPerRow * cgThumb.height)
                    }
                }
                
                // Fallback 1: Direct NSImage decode
                if generatedImage == nil, let direct = NSImage(contentsOf: fileURL) {
                    generatedImage = direct
                    self.imageCache.setObject(direct, forKey: cacheKey as NSString)
                }
                
                // Fallback 2: QuickLook thumbnail representation
                if generatedImage == nil {
                    let request = QLThumbnailGenerator.Request(
                        fileAt: fileURL,
                        size: CGSize(width: maxPixelSize, height: maxPixelSize),
                        scale: 2.0,
                        representationTypes: .thumbnail
                    )
                    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                        let img = rep?.nsImage ?? {
                            let sysIcon = NSWorkspace.shared.icon(forFile: fileURL.path)
                            sysIcon.size = NSSize(width: maxPixelSize, height: maxPixelSize)
                            return sysIcon
                        }()
                        self.imageCache.setObject(img, forKey: cacheKey as NSString)
                        DispatchQueue.main.async {
                            completion(img, extractedDims)
                        }
                    }
                    return
                }
                
                let finalImage = generatedImage
                let finalDims = extractedDims
                DispatchQueue.main.async {
                    completion(finalImage, finalDims)
                }
            } else {
                // For PSD, PDF, Video, Vector, or other documents: use native QuickLook Thumbnailing with NSWorkspace icon fallback
                let request = QLThumbnailGenerator.Request(
                    fileAt: fileURL,
                    size: CGSize(width: maxPixelSize, height: maxPixelSize),
                    scale: 2.0,
                    representationTypes: .thumbnail
                )
                
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                    let img = rep?.nsImage ?? {
                        let sysIcon = NSWorkspace.shared.icon(forFile: fileURL.path)
                        sysIcon.size = NSSize(width: maxPixelSize, height: maxPixelSize)
                        return sysIcon
                    }()
                    self.imageCache.setObject(img, forKey: cacheKey as NSString)
                    DispatchQueue.main.async {
                        completion(img, extractedDims)
                    }
                }
            }
        }
    }
}
