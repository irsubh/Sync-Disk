import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

public enum StorageError: LocalizedError {
    case historyDirectoryNotFound
    case fileNotFound(String)
    case verificationFailed(String)
    case diskFullOrUnavailable
    case atomicWriteFailed(String)
    case restoreFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .historyDirectoryNotFound:
            return "History backup directory is not configured or not accessible."
        case .fileNotFound(let path):
            return "File not found at path: \(path)"
        case .verificationFailed(let msg):
            return "Integrity verification failed: \(msg)"
        case .diskFullOrUnavailable:
            return "External disk is full or not accessible."
        case .atomicWriteFailed(let msg):
            return "Atomic write failed: \(msg)"
        case .restoreFailed(let msg):
            return "Restore failed: \(msg)"
        }
    }
}

public final class HistoryStorageManager: @unchecked Sendable {
    public let historyBaseURL: URL
    private let fileManager = FileManager.default
    
    public init(historyBaseURL: URL) {
        self.historyBaseURL = historyBaseURL
        try? ensureDirectoryExists(at: historyBaseURL)
        try? ensureDirectoryExists(at: historyBaseURL.appendingPathComponent("snapshots", isDirectory: true))
        let neverIndex = historyBaseURL.appendingPathComponent(".metadata_never_index")
        if !fileManager.fileExists(atPath: neverIndex.path) {
            try? Data().write(to: neverIndex)
        }
    }
    
    // MARK: - SHA-256 Checksum Calculation
    
    /// Streams file in 64KB chunks to safely hash arbitrarily large files without high memory usage.
    public func computeSHA256(for fileURL: URL) throws -> String {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw StorageError.fileNotFound(fileURL.path)
        }
        
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        
        var hasher = SHA256()
        let bufferSize = 64 * 1024
        
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: bufferSize)
            if chunk.isEmpty {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Safe Archival to Real Logical Snapshot Structure
    
    /// Archives a file version directly into a real logical snapshot directory (snapshots/<timestamp>/Original Folder/...).
    /// Pure file-based operation with zero internal .store directories.
    public func archiveVersion(
        sourceFileURL: URL,
        logicalPath: String,
        timestamp: Date,
        database: HistoryDatabase? = nil
    ) throws -> (relativePath: String, sha256: String, size: Int64) {
        guard fileManager.fileExists(atPath: sourceFileURL.path) else {
            throw StorageError.fileNotFound(sourceFileURL.path)
        }
        
        let attrs = try fileManager.attributesOfItem(atPath: sourceFileURL.path)
        let sourceSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let sourceSHA = try computeSHA256(for: sourceFileURL)
        
        // 1. Snapshot Directory Structure: snapshots/<timestamp>/<logicalPath>
        let snapshotFolder = snapshotFolderName(for: timestamp)
        let snapshotRelPath = "snapshots/\(snapshotFolder)/\(logicalPath)"
        let finalSnapshotFileURL = historyBaseURL.appendingPathComponent(snapshotRelPath)
        let parentDir = finalSnapshotFileURL.deletingLastPathComponent()
        try ensureDirectoryExists(at: parentDir)
        
        if fileManager.fileExists(atPath: finalSnapshotFileURL.path) {
            try? fileManager.removeItem(at: finalSnapshotFileURL)
        }
        
        // 2. Direct Archival (APFS clonefile when available, fallback to copyItem)
        var cloned = false
        #if canImport(Darwin)
        if Darwin.clonefile(sourceFileURL.path, finalSnapshotFileURL.path, 0) == 0 {
            cloned = true
        }
        #endif
        
        if !cloned {
            if fileManager.fileExists(atPath: finalSnapshotFileURL.path) {
                try? fileManager.removeItem(at: finalSnapshotFileURL)
            }
            try fileManager.copyItem(at: sourceFileURL, to: finalSnapshotFileURL)
        }
        
        return (relativePath: snapshotRelPath, sha256: sourceSHA, size: sourceSize)
    }
    
    public func snapshotFolderName(for date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        df.timeZone = TimeZone.current
        return df.string(from: date)
    }
    
    // MARK: - Safe Atomic Copy for Sync Mirroring
    
    /// Copies source file to destination mirror atomically, verifying byte size and SHA-256.
    public func atomicMirrorCopy(
        sourceFileURL: URL,
        destinationFileURL: URL
    ) throws -> (sha256: String, size: Int64) {
        guard fileManager.fileExists(atPath: sourceFileURL.path) else {
            throw StorageError.fileNotFound(sourceFileURL.path)
        }
        
        let attrs = try fileManager.attributesOfItem(atPath: sourceFileURL.path)
        let sourceSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let sourceSHA = try computeSHA256(for: sourceFileURL)
        
        let parentDir = destinationFileURL.deletingLastPathComponent()
        try ensureDirectoryExists(at: parentDir)
        
        let stagingURL = parentDir.appendingPathComponent(".staging_\(UUID().uuidString)")
        
        do {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try fileManager.removeItem(at: stagingURL)
            }
            try fileManager.copyItem(at: sourceFileURL, to: stagingURL)
            
            let stagingAttrs = try fileManager.attributesOfItem(atPath: stagingURL.path)
            let stagingSize = (stagingAttrs[.size] as? NSNumber)?.int64Value ?? 0
            guard stagingSize == sourceSize else {
                try? fileManager.removeItem(at: stagingURL)
                throw StorageError.verificationFailed("Mirror staging size mismatch")
            }
            
            let stagingSHA = try computeSHA256(for: stagingURL)
            guard stagingSHA == sourceSHA else {
                try? fileManager.removeItem(at: stagingURL)
                throw StorageError.verificationFailed("Mirror staging SHA mismatch")
            }
            
            if fileManager.fileExists(atPath: destinationFileURL.path) {
                try? fileManager.removeItem(at: destinationFileURL)
            }
            try fileManager.moveItem(at: stagingURL, to: destinationFileURL)
            
            return (sha256: sourceSHA, size: sourceSize)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }
    
    // MARK: - Safe Extraction Under Original Logical Filename
    
    /// Extracts a historical version into a clean temporary sandbox location
    /// with its ORIGINAL logical filename (e.g. "AnnualReport.pdf").
    public func extractHistoricalFile(entry: FileHistoryEntry) throws -> URL {
        let historyFileURL = historyBaseURL.appendingPathComponent(entry.historyRelativePath)
        guard fileManager.fileExists(atPath: historyFileURL.path) else {
            throw StorageError.fileNotFound(historyFileURL.path)
        }
        
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncDiskPreview", isDirectory: true)
            .appendingPathComponent(entry.id.uuidString, isDirectory: true)
        
        try ensureDirectoryExists(at: tempRoot)
        let extractedURL = tempRoot.appendingPathComponent(entry.originalFilename)
        
        if fileManager.fileExists(atPath: extractedURL.path) {
            try fileManager.removeItem(at: extractedURL)
        }
        
        try fileManager.copyItem(at: historyFileURL, to: extractedURL)
        return extractedURL
    }
    
    // MARK: - Self-Sufficient Full Snapshot Restoration
    
    /// Restores an entire historical folder snapshot to a target destination directory.
    /// Can operate using the snapshot directory structure directly without database dependency.
    public func restoreFolderSnapshot(snapshotDirURL: URL, toDestinationURL: URL) throws {
        guard fileManager.fileExists(atPath: snapshotDirURL.path) else {
            throw StorageError.fileNotFound(snapshotDirURL.path)
        }
        
        try ensureDirectoryExists(at: toDestinationURL)
        
        let enumerator = fileManager.enumerator(
            at: snapshotDirURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        )
        
        let prefixLen = snapshotDirURL.standardizedFileURL.path.count
        
        while let itemURL = enumerator?.nextObject() as? URL {
            let fullPath = itemURL.standardizedFileURL.path
            guard fullPath.count > prefixLen else { continue }
            let rel = String(fullPath.dropFirst(prefixLen)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            
            // Skip internal metadata files
            if rel == ".manifest.json" || rel.hasPrefix(".staging_") {
                continue
            }
            
            let targetItemURL = toDestinationURL.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    try ensureDirectoryExists(at: targetItemURL)
                } else {
                    let parent = targetItemURL.deletingLastPathComponent()
                    try ensureDirectoryExists(at: parent)
                    if fileManager.fileExists(atPath: targetItemURL.path) {
                        try fileManager.removeItem(at: targetItemURL)
                    }
                    try fileManager.copyItem(at: itemURL, to: targetItemURL)
                }
            }
        }
    }
    
    // MARK: - Staging Cleanup (Crash Recovery)
    
    /// Cleans up any orphaned .staging files left behind by crashes or power loss.
    public func cleanupOrphanedStagingFiles() {
        let enumerator = fileManager.enumerator(at: historyBaseURL, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent.hasPrefix(".staging_") || fileURL.lastPathComponent == ".manifest.json" {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }
    
    // MARK: - Directory Helpers
    
    private func ensureDirectoryExists(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }
}
