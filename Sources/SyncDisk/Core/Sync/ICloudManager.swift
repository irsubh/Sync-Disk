import Foundation

public enum ICloudSyncState: String, Sendable {
    case notDownloaded = "NotDownloaded"
    case downloading = "Downloading"
    case downloaded = "Downloaded"
    case backingUp = "BackingUp"
    case verified = "Verified"
    case evictionPending = "EvictionPending"
    case evicted = "Evicted"
    case failed = "Failed"
}

public final class ICloudManager: @unchecked Sendable {
    private let fileManager = FileManager.default
    
    public init() {}
    
    /// Checks if an item is located in iCloud Drive or recognized as a ubiquitous item.
    public func isUbiquitousItem(at url: URL) -> Bool {
        var u = url
        u.removeAllCachedResourceValues()
        if let values = try? u.resourceValues(forKeys: [.isUbiquitousItemKey]),
           values.isUbiquitousItem == true {
            return true
        }
        let path = url.standardizedFileURL.path
        if path.contains("com~apple~CloudDocs") || path.contains("Mobile Documents") {
            return true
        }
        return false
    }
    
    /// Checks if a file is an iCloud file that is currently not downloaded locally (dataless placeholder).
    public func isDatalessICloudItem(at url: URL) -> Bool {
        var u = url
        u.removeAllCachedResourceValues()
        guard let values = try? u.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]) else {
            return false
        }
        
        guard values.isUbiquitousItem == true else {
            return false
        }
        
        if let status = values.ubiquitousItemDownloadingStatus {
            return status != .current
        }
        return false
    }
    
    /// Executes the full safe iCloud download lifecycle using an explicit state machine.
    /// Returns the final state reached (.downloaded or .failed).
    public func ensureFileDownloaded(at url: URL, timeoutSeconds: TimeInterval = 60.0) async -> ICloudSyncState {
        var u = url
        u.removeAllCachedResourceValues()
        guard isDatalessICloudItem(at: u) else {
            return .downloaded
        }
        
        var state: ICloudSyncState = .notDownloaded
        
        do {
            state = .downloading
            try fileManager.startDownloadingUbiquitousItem(at: u)
            
            let start = Date()
            var delayNanos: UInt64 = 100_000_000 // 100ms
            while Date().timeIntervalSince(start) < timeoutSeconds {
                try await Task.sleep(nanoseconds: delayNanos)
                u.removeAllCachedResourceValues()
                if let values = try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
                   values.ubiquitousItemDownloadingStatus == .current {
                    state = .downloaded
                    return state
                }
                delayNanos = min(500_000_000, delayNanos + 50_000_000)
            }
            
            // Timeout reached
            state = .failed
            return state
        } catch {
            state = .failed
            return state
        }
    }
    
    /// Requests macOS to evict the local copy of an iCloud ubiquitous file, freeing local storage.
    /// CRITICAL SAFETY GUARANTEE:
    /// Eviction is ONLY performed if the verificationState is explicitly `.verified` or `.evictionPending`.
    /// If state is `.failed` or any other state: NO EVICTION!
    @discardableResult
    public func evictLocalCopyIfVerified(at url: URL, verificationState: inout ICloudSyncState) throws -> Bool {
        guard verificationState == .verified || verificationState == .evictionPending else {
            verificationState = .failed
            return false
        }
        
        guard isUbiquitousItem(at: url) else {
            return false
        }
        
        verificationState = .evictionPending
        do {
            try fileManager.evictUbiquitousItem(at: url)
            verificationState = .evicted
            return true
        } catch {
            // In macOS FileProvider, if evictUbiquitousItem fails (e.g. -2008 cache lock), fallback to brctl evict
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/brctl")
            process.arguments = ["evict", url.path]
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                verificationState = .evicted
                return true
            }
            verificationState = .failed
            return false
        }
    }
}
