import Foundation
import Combine

public enum SyncEngineState: String, Sendable {
    case idle = "Idle"
    case watching = "Watching"
    case debouncing = "Debouncing"
    case scanning = "Scanning"
    case copying = "Copying"
    case verifying = "Verifying"
    case committing = "Committing"
    case paused = "Paused"
    case error = "Error"
}

public final class SyncEngine: ObservableObject, @unchecked Sendable {
    public static let shared = SyncEngine()
    
    @Published public var config: SyncConfig
    @Published public var diskStatus: DiskStatus = DiskStatus()
    @Published public var syncProgress: SyncProgress = SyncProgress()
    @Published public var engineState: SyncEngineState = .idle
    @Published public var isEngineActive: Bool = false
    @Published public var historyRevision: Int = 0
    @Published public var lastErrorMessage: String?
    @Published public var activeViewMode: HistoryViewMode = .files
    @Published public var showSettingsSheet: Bool = false
    
    public let database: HistoryDatabase
    public let storageManager: HistoryStorageManager
    public let storageMetrics = StorageMetrics()
    public let fsMonitor = FSEventsMonitor()
    public let diskMonitor = DiskMonitor()
    public let sleepWakeMonitor = SleepWakeMonitor()
    public let renameDetector = RenameDetector()
    public let iCloudManager = ICloudManager()
    
    private let syncQueue = DispatchQueue(label: "com.syncdisk.syncengine", qos: .utility)
    private let fileManager = FileManager.default
    private var isReconciling: Bool = false
    private var isQueuePaused: Bool = false
    
    /// Tracks recently synchronized/evicted paths to prevent self-triggering FSEvent loops.
    private var recentlyHandledPaths: [String: (date: Date, size: Int64, mtime: Date)] = [:]
    private let handledPathsLock = NSLock()
    
    public func markPathHandled(logicalPath: String, size: Int64, mtime: Date) {
        handledPathsLock.lock()
        recentlyHandledPaths[logicalPath] = (date: Date(), size: size, mtime: mtime)
        let threshold = Date().addingTimeInterval(-30)
        recentlyHandledPaths = recentlyHandledPaths.filter { $0.value.date > threshold }
        handledPathsLock.unlock()
    }
    
    public func shouldIgnoreHandledEvent(logicalPath: String, currentSize: Int64, currentMtime: Date) -> Bool {
        handledPathsLock.lock()
        defer { handledPathsLock.unlock() }
        guard let entry = recentlyHandledPaths[logicalPath] else { return false }
        if Date().timeIntervalSince(entry.date) < 15.0 {
            if entry.size == currentSize && abs(entry.mtime.timeIntervalSince(currentMtime)) < 2.0 {
                return true
            }
        }
        return false
    }
    
    public init(config: SyncConfig? = nil, database: HistoryDatabase? = nil, autoStart: Bool = true) {
        let effectiveConfig = config ?? SyncConfig.load()
        self.config = effectiveConfig
        
        let historyURL = effectiveConfig.effectiveHistoryURL ?? SyncConfig.configDirectory.appendingPathComponent("HistoryFallback")
        self.storageManager = HistoryStorageManager(historyBaseURL: historyURL)
        self.database = database ?? HistoryDatabase(storageBaseURL: historyURL)
        
        // Clean up any legacy SQLite database files from local Application Support (zero local DB)
        Self.cleanupLegacyLocalDatabases()
        // Clean up any legacy .store folder from storage
        try? FileManager.default.removeItem(at: historyURL.appendingPathComponent(".store"))
        
        setupMonitors()
        if autoStart {
            start()
        }
    }
    
    private static func cleanupLegacyLocalDatabases() {
        let dir = SyncConfig.configDirectory
        let fm = FileManager.default
        let legacyNames = ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm"]
        for name in legacyNames {
            let u = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) {
                try? fm.removeItem(at: u)
            }
        }
    }
    
    deinit {
        stop()
    }
    
    private func setupMonitors() {
        diskMonitor.onStatusChange = { [weak self] isConnected in
            guard let self = self else { return }
            if isConnected {
                self.database.reloadFromStorage()
            }
            Task { @MainActor in
                self.diskStatus.isConnected = isConnected
                if isConnected {
                    self.syncProgress.statusDescription = "Disk Connected — Resuming Sync"
                    self.isQueuePaused = false
                    self.historyRevision += 1
                    if self.isEngineActive {
                        self.triggerReconcile()
                    }
                } else {
                    self.syncProgress.statusDescription = "Disk Disconnected — Sync Paused"
                    self.isQueuePaused = true
                }
                self.refreshDiskStatus()
            }
        }
        
        diskMonitor.destinationURL = config.syncDestination
        
        sleepWakeMonitor.onSleep = { [weak self] in
            guard let self = self else { return }
            self.syncQueue.async {
                self.isQueuePaused = true
            }
        }
        
        sleepWakeMonitor.onWake = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.isQueuePaused = false
                self.diskMonitor.checkStatus(forceNotify: true)
                self.triggerReconcile()
            }
        }
    }
    
    // MARK: - Engine Lifecycle & Crash Recovery
    
    public func start() {
        guard !isEngineActive else {
            diskMonitor.checkStatus(forceNotify: true)
            refreshDiskStatus(force: true)
            return
        }
        isEngineActive = true
        
        // 1. Crash Recovery on startup
        recoverFromCrash()
        database.reloadFromStorage()
        
        diskMonitor.start()
        
        startFSEventsMonitor()
        
        refreshDiskStatus(force: true)
        triggerReconcile()
    }
    
    private func startFSEventsMonitor() {
        let activePaths = config.sources.filter { $0.isEnabled }.map { $0.url.path }
        var excludedPrefixes: [String] = []
        if let dest = config.syncDestination?.standardizedFileURL.path {
            excludedPrefixes.append(dest)
        }
        if let hist = config.effectiveHistoryURL?.standardizedFileURL.path {
            excludedPrefixes.append(hist)
        }
        fsMonitor.start(
            paths: activePaths,
            excludedPrefixes: excludedPrefixes,
            debounce: max(0.5, config.debounceSeconds)
        ) { [weak self] changedURLs in
            self?.handleFSEvents(changedURLs)
        }
    }
    
    public func stop() {
        isEngineActive = false
        fsMonitor.stop()
        diskMonitor.stop()
        diskMonitor.onStatusChange = nil
    }
    
    public func updateConfig(_ newConfig: SyncConfig) {
        self.config = newConfig
        try? newConfig.save()
        
        diskMonitor.destinationURL = newConfig.syncDestination
        
        if isEngineActive {
            startFSEventsMonitor()
            refreshDiskStatus(force: true)
            triggerReconcile()
        }
    }
    
    /// Startup Crash Recovery: Checks for uncommitted operations, cleans orphaned staging files, and resynchronizes.
    public func recoverFromCrash() {
        syncQueue.sync {
            storageManager.cleanupOrphanedStagingFiles()
            
            if let uncommitted = try? database.uncommittedJournalOperations(), !uncommitted.isEmpty {
                print("Crash Recovery: Found \(uncommitted.count) uncommitted operations. Cleaning up...")
                for op in uncommitted {
                    try? database.updateJournalState(id: op.id, state: .failed)
                }
            }
            database.cleanCommittedJournalOperations()
        }
    }
    
    private var lastDiskStatusCalculation = Date.distantPast
    @MainActor private var isCalculatingDiskStatus = false
    
    public func refreshDiskStatus(force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastDiskStatusCalculation) < 10.0 {
            return
        }
        lastDiskStatusCalculation = now
        
        Task { @MainActor in
            guard !self.isCalculatingDiskStatus else { return }
            self.isCalculatingDiskStatus = true
            defer { self.isCalculatingDiskStatus = false }
            
            let status = await self.storageMetrics.calculateStatus(
                syncDestination: self.config.syncDestination,
                historyDestination: self.config.effectiveHistoryURL,
                sources: self.config.sources,
                database: self.database,
                forceDeepScan: force
            )
            self.diskStatus = status
        }
    }
    
    // MARK: - File System Events Handling
    
    private func handleFSEvents(_ urls: [URL]) {
        guard config.isSyncEnabled, diskMonitor.isConnected, !isQueuePaused else {
            return
        }
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self, !self.isQueuePaused else { return }
            guard let destBase = self.config.syncDestination else { return }
            let destPath = destBase.standardizedFileURL.path
            let histPath = self.config.effectiveHistoryURL?.standardizedFileURL.path
            
            var itemsToSync: [PendingSyncItem] = []
            
            for url in urls {
                let urlStd = url.standardizedFileURL.path
                
                // 1. Strict destination and backup path exclusions
                if urlStd.hasPrefix(destPath) { continue }
                if let hist = histPath, urlStd.hasPrefix(hist) { continue }
                if urlStd.contains("/.backup") || urlStd.contains("/.staging_") { continue }
                
                let filename = url.lastPathComponent
                if self.shouldIgnore(filename: filename) {
                    continue
                }
                
                guard let (source, relPath) = self.resolveSource(for: url) else { continue }
                if self.isPathIgnored(relPath: relPath) { continue }
                let destFileURL = destBase.appendingPathComponent(source.name).appendingPathComponent(relPath)
                let logicalPath = "\(source.name)/\(relPath)"
                
                var isDir: ObjCBool = false
                let sourceFileExists = self.fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
                
                if sourceFileExists {
                    if isDir.boolValue {
                        if !self.fileManager.fileExists(atPath: destFileURL.path) {
                            try? self.fileManager.createDirectory(at: destFileURL, withIntermediateDirectories: true)
                        }
                    } else {
                        // 2. Metadata-first check: Compare size & modDate
                        let attrs = try? self.fileManager.attributesOfItem(atPath: url.path)
                        let currentSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                        let currentMtime = (attrs?[.modificationDate] as? Date) ?? Date()
                        
                        // Check echo loop shield (recent writes/evictions by Sync Disk)
                        if self.shouldIgnoreHandledEvent(logicalPath: logicalPath, currentSize: currentSize, currentMtime: currentMtime) {
                            continue
                        }
                        
                        // Check dataless iCloud item guard
                        if self.iCloudManager.isDatalessICloudItem(at: url) {
                            if let existing = try? self.database.latestVersion(for: logicalPath, sourceId: source.id), existing.fileSize > 0 {
                                // Already recorded in history & mirror; dataless transition must not trigger download loop
                                continue
                            }
                        }
                        
                        // Compare against latest recorded version in database
                        if let latest = try? self.database.latestVersion(for: logicalPath, sourceId: source.id) {
                            if latest.fileSize == currentSize && abs(latest.timestamp.timeIntervalSince(currentMtime)) < 2.0 {
                                // Metadata is identical. No content change!
                                continue
                            }
                        }
                        
                        itemsToSync.append(PendingSyncItem(
                            sourceURL: url,
                            destinationURL: destFileURL,
                            logicalPath: logicalPath,
                            sourceId: source.id
                        ))
                    }
                } else {
                    try? self.deleteFileFromDestination(destinationURL: destFileURL, logicalPath: logicalPath, sourceId: source.id)
                }
            }
            
            if !itemsToSync.isEmpty {
                await MainActor.run {
                    self.engineState = .copying
                    self.syncProgress.isSyncing = true
                }
                
                let maxConcurrent = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount))
                await withTaskGroup(of: Void.self) { group in
                    var inFlight = 0
                    for item in itemsToSync {
                        guard !self.isQueuePaused else { break }
                        if inFlight >= maxConcurrent {
                            await group.next()
                            inFlight -= 1
                        }
                        inFlight += 1
                        group.addTask {
                            do {
                                try await self.syncFileToDestination(
                                    sourceURL: item.sourceURL,
                                    destinationURL: item.destinationURL,
                                    logicalPath: item.logicalPath,
                                    sourceId: item.sourceId
                                )
                            } catch {
                                print("Parallel event sync error for \(item.logicalPath): \(error)")
                                await MainActor.run {
                                    self.lastErrorMessage = error.localizedDescription
                                }
                            }
                        }
                    }
                    await group.waitForAll()
                }
                self.database.flushIndex()
                
                await MainActor.run {
                    self.historyRevision += 1
                    self.engineState = .idle
                    self.syncProgress.isSyncing = false
                    self.syncProgress.statusDescription = "Idle — Everything up to date"
                }
            } else {
                await MainActor.run {
                    self.engineState = .idle
                }
            }
            
            self.refreshDiskStatus(force: false)
        }
    }
    
    // MARK: - Core Synchronization with Safety Archiving & Deduplication
    
    /// Syncs a single file from Mac source to external destination.
    public func syncFileToDestination(
        sourceURL: URL,
        destinationURL: URL,
        logicalPath: String,
        sourceId: UUID
    ) async throws {
        guard diskMonitor.isConnected, !isQueuePaused else { return }
        
        // 1. Journal operation start
        let journalId = try database.startJournalOperation(
            opType: "sync",
            sourcePath: sourceURL.path,
            destinationPath: destinationURL.path,
            logicalPath: logicalPath
        )
        
        let originalFilename = (logicalPath as NSString).lastPathComponent
        let destExists = fileManager.fileExists(atPath: destinationURL.path)
        let now = Date()
        
        // 2. iCloud State Machine Handling
        var iCloudState: ICloudSyncState = .notDownloaded
        if iCloudManager.isDatalessICloudItem(at: sourceURL) {
            await MainActor.run {
                self.syncProgress.statusDescription = "Downloading \(originalFilename) from iCloud..."
            }
            iCloudState = await self.iCloudManager.ensureFileDownloaded(at: sourceURL)
            
            if iCloudState == .failed {
                try database.updateJournalState(id: journalId, state: .failed)
                throw NSError(domain: "SyncEngine", code: 408, userInfo: [NSLocalizedDescriptionKey: "iCloud file failed to download: \(sourceURL.lastPathComponent)"])
            }
        }
        
        try database.updateJournalState(id: journalId, state: .copying)
        
        // 3. Conflict Protection & Prior Version Preservation
        let latestVersion = try database.latestVersion(for: logicalPath, sourceId: sourceId)
        
        if destExists {
            let destAttrs = try fileManager.attributesOfItem(atPath: destinationURL.path)
            let destSize = (destAttrs[.size] as? NSNumber)?.int64Value ?? 0
            let destModDate = (destAttrs[.modificationDate] as? Date) ?? now
            
            let srcAttrs = try fileManager.attributesOfItem(atPath: sourceURL.path)
            let srcSize = (srcAttrs[.size] as? NSNumber)?.int64Value ?? 0
            let srcModDate = (srcAttrs[.modificationDate] as? Date) ?? now
            
            // Fast path: If destination already matches source metadata, skip duplicate sync!
            if destSize == srcSize && abs(destModDate.timeIntervalSince(srcModDate)) < 2.0 {
                self.markPathHandled(logicalPath: logicalPath, size: srcSize, mtime: srcModDate)
                try? database.updateJournalState(id: journalId, state: .committed)
                return
            }
            
            // Check if destination was manually edited externally (conflict protection)
            let destSHA = try? storageManager.computeSHA256(for: destinationURL)
            let sourceSHA = try? storageManager.computeSHA256(for: sourceURL)
            let isExternalDestinationEdit = (latestVersion != nil && destSHA != nil && destSHA != latestVersion?.sha256 && destSHA != sourceSHA)
            let isUnrecordedDestination = (latestVersion == nil && destSHA != nil && destSHA != sourceSHA)
            
            // If the destination file was edited externally or was never recorded with different content, archive it
            if isExternalDestinationEdit || isUnrecordedDestination {
                let (relHistPath, histSHA, histSize) = try storageManager.archiveVersion(
                    sourceFileURL: destinationURL,
                    logicalPath: logicalPath,
                    timestamp: destModDate,
                    database: database
                )
                
                let priorVerNum = try database.nextVersionNumber(for: logicalPath, sourceId: sourceId)
                try database.markPreviousVersionsNotCurrent(logicalPath: logicalPath, sourceId: sourceId)
                
                let histEntry = FileHistoryEntry(
                    sourceId: sourceId,
                    logicalPath: logicalPath,
                    originalFilename: originalFilename,
                    timestamp: destModDate,
                    changeType: .modified,
                    fileSize: histSize,
                    sha256: histSHA,
                    historyRelativePath: relHistPath,
                    isCurrentVersion: false,
                    versionNumber: priorVerNum
                )
                try database.insert(version: histEntry)
                
                if isExternalDestinationEdit {
                    print("SyncEngine: Conflict protected — external destination modification preserved in history.")
                }
            }
        }
        
        // 4. Archive the new version into History Storage (capturing initial and all subsequent versions)
        let (sourceRelHistPath, sourceSHA, sourceSize) = try storageManager.archiveVersion(
            sourceFileURL: sourceURL,
            logicalPath: logicalPath,
            timestamp: now,
            database: database
        )
        
        try database.updateJournalState(id: journalId, state: .verifying)
        
        // 5. Mirror to external destination
        let (mirrorSHA, mirrorSize) = try storageManager.atomicMirrorCopy(
            sourceFileURL: sourceURL,
            destinationFileURL: destinationURL
        )
        
        guard mirrorSHA == sourceSHA, mirrorSize == sourceSize else {
            try database.updateJournalState(id: journalId, state: .failed)
            throw StorageError.verificationFailed("Mirror copy verification mismatch")
        }
        
        // 6. Record current version in database
        try database.markPreviousVersionsNotCurrent(logicalPath: logicalPath, sourceId: sourceId)
        let currentVerNum = try database.nextVersionNumber(for: logicalPath, sourceId: sourceId)
        
        let newEntry = FileHistoryEntry(
            sourceId: sourceId,
            logicalPath: logicalPath,
            originalFilename: originalFilename,
            timestamp: now,
            changeType: destExists ? .modified : .created,
            fileSize: mirrorSize,
            sha256: mirrorSHA,
            historyRelativePath: sourceRelHistPath,
            isCurrentVersion: true,
            versionNumber: currentVerNum
        )
        try database.insert(version: newEntry)
        
        // 7. Mark Journal operation as committed
        try database.updateJournalState(id: journalId, state: .committed)
        
        self.markPathHandled(logicalPath: logicalPath, size: mirrorSize, mtime: now)
        self.storageMetrics.updateCachedSizes(syncedDelta: mirrorSize, historyDelta: sourceSize)
        
        // 8. Safe iCloud Eviction: ONLY after external backup is verified!
        if config.evictICloudAfterSync && (iCloudState == .downloaded || iCloudManager.isUbiquitousItem(at: sourceURL)) {
            var verificationState: ICloudSyncState = .verified
            self.markPathHandled(logicalPath: logicalPath, size: mirrorSize, mtime: now)
            _ = try? iCloudManager.evictLocalCopyIfVerified(at: sourceURL, verificationState: &verificationState)
        }
        
        await MainActor.run {
            self.syncProgress.currentFileName = originalFilename
            self.syncProgress.lastSyncDate = Date()
            self.syncProgress.statusDescription = "Synced \(originalFilename)"
        }
    }
    
    /// Handles deletion on Mac:
    /// - Preserves file in History with .deleted change type.
    /// - Removes file from destination mirror.
    public func deleteFileFromDestination(
        destinationURL: URL,
        logicalPath: String,
        sourceId: UUID
    ) throws {
        guard diskMonitor.isConnected, !isQueuePaused else { return }
        let originalFilename = (logicalPath as NSString).lastPathComponent
        let now = Date()
        
        let journalId = try database.startJournalOperation(
            opType: "delete",
            sourcePath: "",
            destinationPath: destinationURL.path,
            logicalPath: logicalPath
        )
        
        if fileManager.fileExists(atPath: destinationURL.path) {
            let (relHistPath, histSHA, histSize) = try storageManager.archiveVersion(
                sourceFileURL: destinationURL,
                logicalPath: logicalPath,
                timestamp: now,
                database: database
            )
            
            try fileManager.removeItem(at: destinationURL)
            try database.markPreviousVersionsNotCurrent(logicalPath: logicalPath, sourceId: sourceId)
            let delVerNum = try database.nextVersionNumber(for: logicalPath, sourceId: sourceId)
            
            let deleteEntry = FileHistoryEntry(
                sourceId: sourceId,
                logicalPath: logicalPath,
                originalFilename: originalFilename,
                timestamp: now,
                changeType: .deleted,
                fileSize: histSize,
                sha256: histSHA,
                historyRelativePath: relHistPath,
                isCurrentVersion: false,
                versionNumber: delVerNum
            )
            try database.insert(version: deleteEntry)
        } else {
            try database.markPreviousVersionsNotCurrent(logicalPath: logicalPath, sourceId: sourceId)
            let delVerNum = try database.nextVersionNumber(for: logicalPath, sourceId: sourceId)
            let deleteEntry = FileHistoryEntry(
                sourceId: sourceId,
                logicalPath: logicalPath,
                originalFilename: originalFilename,
                timestamp: now,
                changeType: .deleted,
                fileSize: 0,
                sha256: "",
                historyRelativePath: "",
                isCurrentVersion: false,
                versionNumber: delVerNum
            )
            try database.insert(version: deleteEntry)
        }
        
        try database.updateJournalState(id: journalId, state: .committed)
        
        DispatchQueue.main.async {
            self.syncProgress.statusDescription = "Removed \(originalFilename)"
        }
    }
    
    // MARK: - Safe Restore
    
    public func restoreVersion(entry: FileHistoryEntry, toTargetURL: URL? = nil) async throws {
        guard let source = config.sources.first(where: { $0.id == entry.sourceId }) else {
            throw NSError(domain: "SyncEngine", code: 404, userInfo: [NSLocalizedDescriptionKey: "Source folder not found for this version."])
        }
        
        var relPath = entry.logicalPath
        if relPath.hasPrefix(source.name + "/") {
            relPath = String(relPath.dropFirst((source.name + "/").count))
        }
        
        let targetURL = toTargetURL ?? source.url.appendingPathComponent(relPath)
        let parentDir = targetURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        
        let historyFileURL = storageManager.historyBaseURL.appendingPathComponent(entry.historyRelativePath)
        guard fileManager.fileExists(atPath: historyFileURL.path) else {
            throw StorageError.fileNotFound(historyFileURL.path)
        }
        
        let now = Date()
        
        if fileManager.fileExists(atPath: targetURL.path) {
            let (relHistPath, curSHA, curSize) = try storageManager.archiveVersion(
                sourceFileURL: targetURL,
                logicalPath: entry.logicalPath,
                timestamp: now,
                database: database
            )
            let prevVerNum = try database.nextVersionNumber(for: entry.logicalPath, sourceId: entry.sourceId)
            let prevEntry = FileHistoryEntry(
                sourceId: entry.sourceId,
                logicalPath: entry.logicalPath,
                originalFilename: entry.originalFilename,
                timestamp: now,
                changeType: .modified,
                fileSize: curSize,
                sha256: curSHA,
                historyRelativePath: relHistPath,
                isCurrentVersion: false,
                versionNumber: prevVerNum
            )
            try database.insert(version: prevEntry)
        }
        
        _ = try storageManager.atomicMirrorCopy(sourceFileURL: historyFileURL, destinationFileURL: targetURL)
        
        if let destBase = config.syncDestination {
            let destFileURL = destBase.appendingPathComponent(source.name).appendingPathComponent(relPath)
            _ = try storageManager.atomicMirrorCopy(sourceFileURL: targetURL, destinationFileURL: destFileURL)
        }
        
        try database.markPreviousVersionsNotCurrent(logicalPath: entry.logicalPath, sourceId: entry.sourceId)
        let restoredVerNum = try database.nextVersionNumber(for: entry.logicalPath, sourceId: entry.sourceId)
        let restoredEntry = FileHistoryEntry(
            sourceId: entry.sourceId,
            logicalPath: entry.logicalPath,
            originalFilename: entry.originalFilename,
            timestamp: Date(),
            changeType: .modified,
            fileSize: entry.fileSize,
            sha256: entry.sha256,
            historyRelativePath: entry.historyRelativePath,
            isCurrentVersion: true,
            versionNumber: restoredVerNum
        )
        try database.insert(version: restoredEntry)
        
        await MainActor.run {
            self.syncProgress.statusDescription = "Restored \(entry.originalFilename)"
            self.refreshDiskStatus()
        }
    }
    
    /// Restores the entire historical point-in-time directory state as it existed at the given date.
    public func restoreFullFolderSnapshot(at date: Date) async throws {
        let snapshot = try database.folderSnapshot(path: "", at: date)
        
        func extractEntries(from items: [FolderSnapshotItem]) -> [FileHistoryEntry] {
            var list: [FileHistoryEntry] = []
            for item in items {
                if item.isDirectory {
                    list.append(contentsOf: extractEntries(from: item.children))
                } else if let entry = item.fileEntry {
                    list.append(entry)
                }
            }
            return list
        }
        
        let entries = extractEntries(from: snapshot.items)
        guard !entries.isEmpty else { return }
        
        for entry in entries {
            try await restoreVersion(entry: entry)
        }
        
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let dateStr = df.string(from: date)
        
        await MainActor.run {
            self.syncProgress.statusDescription = "Restored snapshot (\(dateStr))"
            self.refreshDiskStatus()
        }
    }
    
    // MARK: - Reconciliation Scan (Authoritative Source of Truth)
    
    public func triggerReconcile() {
        diskMonitor.checkStatus(forceNotify: false)
        guard config.isSyncEnabled, diskMonitor.isConnected, !isReconciling else { return }
        self.isQueuePaused = false
        
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self, !self.isReconciling else { return }
            self.isReconciling = true
            
            await MainActor.run {
                self.engineState = .scanning
                self.syncProgress.isSyncing = true
                self.syncProgress.statusDescription = "Reconciling changes..."
            }
            
            await self.reconcileAllSourcesInternal()
            
            await MainActor.run {
                self.engineState = .idle
                self.syncProgress.isSyncing = false
                self.syncProgress.statusDescription = "Idle — Everything up to date"
                self.isReconciling = false
            }
            self.refreshDiskStatus(force: false)
        }
    }
    
    private func reconcileAllSourcesInternal() async {
        guard let destBase = config.syncDestination else { return }
        
        for source in config.sources where source.isEnabled {
            guard !isQueuePaused else { return }
            guard fileManager.fileExists(atPath: source.url.path) else { continue }
            
            var itemsToSync: [PendingSyncItem] = []
            
            let enumerator = fileManager.enumerator(
                at: source.url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            while let fileURL = enumerator?.nextObject() as? URL {
                guard !isQueuePaused else { return }
                
                let filename = fileURL.lastPathComponent
                if shouldIgnore(filename: filename) {
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                        enumerator?.skipDescendants()
                    }
                    continue
                }
                
                guard let (src, relPath) = resolveSource(for: fileURL) else { continue }
                if isPathIgnored(relPath: relPath) {
                    enumerator?.skipDescendants()
                    continue
                }
                let destFileURL = destBase.appendingPathComponent(src.name).appendingPathComponent(relPath)
                let logicalPath = "\(src.name)/\(relPath)"
                
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir) else { continue }
                
                if isDir.boolValue {
                    if !fileManager.fileExists(atPath: destFileURL.path) {
                        try? fileManager.createDirectory(at: destFileURL, withIntermediateDirectories: true)
                    }
                    continue
                }
                
                let destExists = fileManager.fileExists(atPath: destFileURL.path)
                let latestVersion = try? database.latestVersion(for: logicalPath, sourceId: src.id)
                
                if destExists {
                    let srcAttrs = try? fileManager.attributesOfItem(atPath: fileURL.path)
                    let destAttrs = try? fileManager.attributesOfItem(atPath: destFileURL.path)
                    let srcSize = (srcAttrs?[.size] as? NSNumber)?.int64Value ?? 0
                    let destSize = (destAttrs?[.size] as? NSNumber)?.int64Value ?? 0
                    let srcDate = srcAttrs?[.modificationDate] as? Date
                    let destDate = destAttrs?[.modificationDate] as? Date
                    
                    let isIdentical = (srcSize == destSize) && (srcDate == nil || destDate == nil || destDate! >= srcDate! || abs(destDate!.timeIntervalSince(srcDate!)) < 2.0)
                    
                    if isIdentical {
                        if latestVersion == nil {
                            let now = srcDate ?? Date()
                            try? database.recordVersion(
                                sourceId: src.id,
                                logicalPath: logicalPath,
                                originalFilename: filename,
                                timestamp: now,
                                changeType: .created,
                                previousPath: nil,
                                fileSize: srcSize,
                                sha256: "",
                                historyRelativePath: "\(src.name)/\(relPath)"
                            )
                        }
                        continue
                    }
                }
                
                itemsToSync.append(PendingSyncItem(
                    sourceURL: fileURL,
                    destinationURL: destFileURL,
                    logicalPath: logicalPath,
                    sourceId: src.id
                ))
            }
            
            guard !itemsToSync.isEmpty else { continue }
            
            let totalCount = itemsToSync.count
            var completedCount = 0
            var lastReportDate = Date.distantPast
            let maxConcurrent = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
            
            await MainActor.run {
                self.syncProgress.statusDescription = "Syncing \(source.name) (\(totalCount) files)..."
            }
            
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0
                for item in itemsToSync {
                    guard !self.isQueuePaused else { break }
                    if inFlight >= maxConcurrent {
                        await group.next()
                        inFlight -= 1
                    }
                    inFlight += 1
                    group.addTask {
                        do {
                            try await self.syncFileToDestination(
                                sourceURL: item.sourceURL,
                                destinationURL: item.destinationURL,
                                logicalPath: item.logicalPath,
                                sourceId: item.sourceId
                            )
                        } catch {
                            print("Reconcile parallel error for \(item.logicalPath): \(error)")
                            await MainActor.run {
                                self.lastErrorMessage = error.localizedDescription
                            }
                        }
                    }
                    
                    completedCount += 1
                    let now = Date()
                    if now.timeIntervalSince(lastReportDate) >= 0.75 || completedCount == totalCount {
                        lastReportDate = now
                        let done = completedCount
                        await MainActor.run {
                            self.syncProgress.statusDescription = "Syncing \(source.name) (\(done)/\(totalCount))..."
                        }
                    }
                }
                await group.waitForAll()
            }
            
            self.database.flushIndex()
            await MainActor.run {
                self.historyRevision += 1
            }
        }
    }
    
    // MARK: - Path Resolving Helpers
    
    public static let ignoredFolderNames: Set<String> = [
        "node_modules", ".git", ".build", "build", "dist", "out", "DerivedData", "vendor", "Pods", "__pycache__", ".next", ".nuxt", ".cache", ".turbo", ".venv", "venv", "target"
    ]
    
    public func isPathIgnored(relPath: String) -> Bool {
        let parts = relPath.split(separator: "/")
        return parts.contains { Self.ignoredFolderNames.contains(String($0)) }
    }
    
    private func shouldIgnore(filename: String) -> Bool {
        if filename.hasPrefix(".") || filename == ".DS_Store" || filename == ".localized" || filename.hasPrefix(".Spotlight") || filename == ".Trashes" || filename == ".fseventsd" {
            return true
        }
        if filename.contains(".sb-") || filename.hasPrefix(".staging_") || filename.hasSuffix(".tmp") {
            return true
        }
        if Self.ignoredFolderNames.contains(filename) {
            return true
        }
        return false
    }
    
    private func resolveSource(for url: URL) -> (source: SyncSource, relativePath: String)? {
        let filePath = url.standardizedFileURL.path
        for source in config.sources where source.isEnabled {
            let srcPath = source.url.standardizedFileURL.path
            if filePath.hasPrefix(srcPath) {
                var rel = String(filePath.dropFirst(srcPath.count))
                if rel.hasPrefix("/") { rel.removeFirst() }
                return (source, rel)
            }
        }
        return nil
    }
    
    /// Resolves a logical path (e.g. "Documents/nodezed/social/avatar/main.png") to an actual on-disk URL.
    /// Checks live source folders first, then sync mirror destination, then history store.
    public func resolveURL(for logicalPath: String) -> URL? {
        let fm = FileManager.default
        
        // 1. Check live source directories
        for source in config.sources where source.isEnabled {
            let prefix = source.name + "/"
            if logicalPath.hasPrefix(prefix) {
                let sub = String(logicalPath.dropFirst(prefix.count))
                let u = source.url.appendingPathComponent(sub)
                if fm.fileExists(atPath: u.path) {
                    return u
                }
            } else if logicalPath == source.name {
                if fm.fileExists(atPath: source.url.path) {
                    return source.url
                }
            }
        }
        
        // 2. Check mirror destination (e.g. /Volumes/SanDisk/Documents/...)
        if let dest = config.syncDestination {
            let u = dest.appendingPathComponent(logicalPath)
            if fm.fileExists(atPath: u.path) {
                return u
            }
        }
        
        // 3. Check history store
        let historyBase = config.effectiveHistoryURL ?? storageManager.historyBaseURL
        let directHist = historyBase.appendingPathComponent(logicalPath)
        if fm.fileExists(atPath: directHist.path) {
            return directHist
        }
        
        return nil
    }
}

public struct PendingSyncItem: Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let logicalPath: String
    public let sourceId: UUID
    
    public init(sourceURL: URL, destinationURL: URL, logicalPath: String, sourceId: UUID) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.logicalPath = logicalPath
        self.sourceId = sourceId
    }
}
