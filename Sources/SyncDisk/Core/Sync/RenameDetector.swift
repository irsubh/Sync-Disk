import Foundation

public struct RenameEvent: Sendable {
    public let oldLogicalPath: String
    public let newLogicalPath: String
    public let oldFilename: String
    public let newFilename: String
    public let newFileURL: URL
    public let sourceId: UUID
    
    public init(
        oldLogicalPath: String,
        newLogicalPath: String,
        oldFilename: String,
        newFilename: String,
        newFileURL: URL,
        sourceId: UUID
    ) {
        self.oldLogicalPath = oldLogicalPath
        self.newLogicalPath = newLogicalPath
        self.oldFilename = oldFilename
        self.newFilename = newFilename
        self.newFileURL = newFileURL
        self.sourceId = sourceId
    }
}

public final class RenameDetector: @unchecked Sendable {
    private let fileManager = FileManager.default
    
    public init() {}
    
    /// Obtains POSIX file system inode number for tracking file identities across renames.
    public func fileInode(for url: URL) -> UInt64? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let num = attrs[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return num.uint64Value
    }
    
    /// Detects renames by correlating missing files with newly appeared files in the source tree.
    public func correlateRenames(
        deletedPaths: [String],
        createdURLs: [URL],
        sourceBaseURL: URL,
        sourceId: UUID,
        database: HistoryDatabase
    ) -> (renames: [RenameEvent], remainingDeletes: [String], remainingCreates: [URL]) {
        var detectedRenames: [RenameEvent] = []
        var remainingDeletes = Set(deletedPaths)
        var remainingCreates = createdURLs
        
        // Match by file content hash or inode
        for createURL in remainingCreates {
            guard fileManager.fileExists(atPath: createURL.path) else { continue }
            
            // Compute relative path
            let fullSource = sourceBaseURL.standardizedFileURL.path
            let fullTarget = createURL.standardizedFileURL.path
            guard fullTarget.hasPrefix(fullSource) else { continue }
            
            var newRel = String(fullTarget.dropFirst(fullSource.count))
            if newRel.hasPrefix("/") { newRel.removeFirst() }
            
            // Check if any deleted path matches the latest hash in database
            guard let createAttrs = try? fileManager.attributesOfItem(atPath: createURL.path),
                  let createSize = (createAttrs[.size] as? NSNumber)?.int64Value else {
                continue
            }
            
            for delPath in remainingDeletes {
                if let latestVer = try? database.latestVersion(for: delPath, sourceId: sourceId),
                   latestVer.changeType != .deleted,
                   latestVer.fileSize == createSize {
                    // Possible rename! Verify hash
                    let storageMgr = HistoryStorageManager(historyBaseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
                    if let newSHA = try? storageMgr.computeSHA256(for: createURL),
                       newSHA == latestVer.sha256 {
                        
                        let oldName = (delPath as NSString).lastPathComponent
                        let newName = createURL.lastPathComponent
                        
                        detectedRenames.append(RenameEvent(
                            oldLogicalPath: delPath,
                            newLogicalPath: newRel,
                            oldFilename: oldName,
                            newFilename: newName,
                            newFileURL: createURL,
                            sourceId: sourceId
                        ))
                        
                        remainingDeletes.remove(delPath)
                        remainingCreates.removeAll(where: { $0 == createURL })
                        break
                    }
                }
            }
        }
        
        return (detectedRenames, Array(remainingDeletes), remainingCreates)
    }
}
