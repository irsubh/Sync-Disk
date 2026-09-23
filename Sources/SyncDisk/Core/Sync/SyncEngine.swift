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
    case restoring = "Restoring"
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
    
    @Published public var isRestoring: Bool = false
    @Published public var restoreTitle: String = ""
    @Published public var restoreProgress: Double = 0.0
    @Published public var restoreCurrentFile: Int = 0
    @Published public var restoreTotalFiles: Int = 0
    
    /// User-specific toggle to pause/resume live background syncing
    @Published public var isLiveSyncPaused: Bool = false
    
    @MainActor
    public func toggleLiveSyncing() {
        isLiveSyncPaused.toggle()
        if isLiveSyncPaused {
            isQueuePaused = true
            engineState = .paused
            syncProgress.isSyncing = false
            syncProgress.statusDescription = "Live Sync Paused"
        } else {
            if !isRestoring {
                isQueuePaused = false
                engineState = .idle
                syncProgress.statusDescription = "Live Sync Active"
                if isEngineActive && diskMonitor.isConnected {
                    triggerReconcile()
                }
            }
        }
    }
    
    public private(set) var database: HistoryDatabase
    public private(set) var storageManager: HistoryStorageManager
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
    
    private var liveSyncBytesDelta: Int64 = 0
    private var liveSyncFilesDelta: Int = 0
    private var lastLiveDiskStatusUpdate: Date = Date.distantPast
    private let liveMetricsLock = NSLock()
    
    public func recordLiveSyncProgress(bytes: Int64, isNewFile: Bool) {
        liveMetricsLock.lock()
        liveSyncBytesDelta += bytes
        if isNewFile {
            liveSyncFilesDelta += 1
        }
        let now = Date()
        let shouldFlush = now.timeIntervalSince(lastLiveDiskStatusUpdate) >= 0.35
        var flushedBytes: Int64 = 0
        var flushedFiles: Int = 0
        if shouldFlush {
            flushedBytes = liveSyncBytesDelta
            flushedFiles = liveSyncFilesDelta
            liveSyncBytesDelta = 0
            liveSyncFilesDelta = 0
            lastLiveDiskStatusUpdate = now
        }
        liveMetricsLock.unlock()
        
        if flushedBytes > 0 || flushedFiles > 0 {
            Task { @MainActor in
                self.diskStatus.syncedSizeBytes += flushedBytes
                self.diskStatus.totalFilesCount += flushedFiles
                if self.diskStatus.totalSpaceBytes > 0 {
                    self.diskStatus.freeSpaceBytes = max(0, self.diskStatus.freeSpaceBytes - flushedBytes)
                }
            }
        }
    }
    
    public func flushLiveSyncProgress() {
        liveMetricsLock.lock()
        let flushedBytes = liveSyncBytesDelta
        let flushedFiles = liveSyncFilesDelta
        liveSyncBytesDelta = 0
        liveSyncFilesDelta = 0
        liveMetricsLock.unlock()
        
        if flushedBytes > 0 || flushedFiles > 0 {
            Task { @MainActor in
                self.diskStatus.syncedSizeBytes += flushedBytes
                self.diskStatus.totalFilesCount += flushedFiles
                if self.diskStatus.totalSpaceBytes > 0 {
                    self.diskStatus.freeSpaceBytes = max(0, self.diskStatus.freeSpaceBytes - flushedBytes)
                }
            }
        }
    }
    
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
        // Only ignore if the file size and mtime match what was recently handled (echo suppression).
        // If the file changed (e.g. was dataless/size 0, now has data, or mtime changed), do NOT ignore!
        if entry.size == currentSize && abs(entry.mtime.timeIntervalSince(currentMtime)) < 1.0 {
            return true
        }
        return false
    }
    
    public init(config: SyncConfig? = nil, database: HistoryDatabase? = nil, autoStart: Bool = true) {
        var effectiveConfig = config ?? SyncConfig.load()
        
        // Auto-detect mounted external SanDisk drive if no destination is configured
        if effectiveConfig.syncDestination == nil {
            let sandiskURL = URL(fileURLWithPath: "/Volumes/SanDisk")
            if FileManager.default.fileExists(atPath: sandiskURL.path) {
                effectiveConfig.syncDestination = sandiskURL
                try? effectiveConfig.save()
            }
        }
        self.config = effectiveConfig
        
        // History location must ONLY ever be on the external drive (.backup).
        // If destination drive is not connected/configured, use a safe unmounted external placeholder.
        // NEVER use internal Application Support or fallback to local disk!
        let historyURL = effectiveConfig.effectiveHistoryURL ?? URL(fileURLWithPath: "/Volumes/.NoExternalDiskConnected/.backup")
        self.storageManager = HistoryStorageManager(historyBaseURL: historyURL)
        self.database = database ?? HistoryDatabase(storageBaseURL: historyURL)
        
        // Clean up any legacy SQLite database files or old HistoryFallback folders from local Application Support (zero local backup data)
        Self.cleanupLegacyLocalDatabases()
        // Clean up any legacy .store folder from storage if mounted
        if FileManager.default.fileExists(atPath: historyURL.path) {
            try? FileManager.default.removeItem(at: historyURL.appendingPathComponent(".store"))
        }
        
        setupMonitors()
        if autoStart {
            start()
        }
    }
    
    private static func cleanupLegacyLocalDatabases() {
        let dir = SyncConfig.configDirectory
        let fm = FileManager.default
        let legacyNames = [
            "history.sqlite",
            "history.sqlite-wal",
            "history.sqlite-shm",
            "HistoryFallback",
            "snapshots",
            "history_index.json",
            ".metadata_never_index"
        ]
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
                self.updateHistoryLocationIfNeeded()
                self.database.reloadFromStorage()
            }
            Task { @MainActor in
                self.diskStatus.isConnected = isConnected
                if isConnected {
                    self.isQueuePaused = self.isLiveSyncPaused
                    self.historyRevision += 1
                    if self.isLiveSyncPaused {
                        self.syncProgress.statusDescription = "Disk Connected — Live Sync Paused"
                    } else {
                        self.syncProgress.statusDescription = "Disk Connected — Resuming Sync"
                        if self.isEngineActive {
                            self.triggerReconcile()
                        }
                    }
                } else {
                    self.syncProgress.statusDescription = "Disk Disconnected — Sync Paused"
                    self.isQueuePaused = true
                }
                self.refreshDiskStatus()
            }
        }
        
        diskMonitor.destinationURL = config.syncDestination
        diskMonitor.onPeriodicCheck = { [weak self] in
            self?.checkDestinationMirrorHealth()
        }
        
        sleepWakeMonitor.onSleep = { [weak self] in
            guard let self = self else { return }
            self.syncQueue.async {
                self.isQueuePaused = true
            }
        }
        
        sleepWakeMonitor.onWake = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.isQueuePaused = self.isLiveSyncPaused
                self.diskMonitor.checkStatus(forceNotify: true)
                if !self.isLiveSyncPaused {
                    self.triggerReconcile()
                }
            }
        }
    }
    
    // MARK: - Engine Lifecycle & Crash Recovery
    
    public func start() {
        guard !isEngineActive else {
            updateHistoryLocationIfNeeded()
            diskMonitor.checkStatus(forceNotify: true)
            refreshDiskStatus(force: true)
            return
        }
        isEngineActive = true
        
        updateHistoryLocationIfNeeded()
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
            debounce: max(0.2, config.debounceSeconds)
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
    
    public func updateHistoryLocationIfNeeded() {
        guard let dest = config.syncDestination, diskMonitor.isConnected else { return }
        let targetHistoryURL = config.effectiveHistoryURL ?? dest.appendingPathComponent(".backup", isDirectory: true)
        
        guard !HistoryStorageManager.isForbiddenInternalStorage(url: targetHistoryURL) else {
            print("SyncDisk Error: Prohibited attempt to use internal storage for history: \(targetHistoryURL.path)")
            return
        }
        
        if storageManager.historyBaseURL.standardizedFileURL.path != targetHistoryURL.standardizedFileURL.path {
            self.storageManager = HistoryStorageManager(historyBaseURL: targetHistoryURL)
            self.database = HistoryDatabase(storageBaseURL: targetHistoryURL)
            self.historyRevision += 1
        }
    }
    
    public func updateConfig(_ newConfig: SyncConfig) {
        self.config = newConfig
        try? newConfig.save()
        
        diskMonitor.destinationURL = newConfig.syncDestination
        updateHistoryLocationIfNeeded()
        
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
        if !force && now.timeIntervalSince(lastDiskStatusCalculation) < 3.0 {
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
        guard config.isSyncEnabled, diskMonitor.isConnected, !isQueuePaused, !isRestoring, !isLiveSyncPaused else {
            return
        }
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self, !self.isQueuePaused, !self.isRestoring, !self.isLiveSyncPaused else { return }
            guard let destBase = self.config.syncDestination else { return }
            let destPath = destBase.standardizedFileURL.path
            let histPath = self.config.effectiveHistoryURL?.standardizedFileURL.path
            
            var itemsToSync: [PendingSyncItem] = []
            var didChangeFilesystem = false
            
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
                            didChangeFilesystem = true
                        } else {
                            // Check for deleted items: items on destination mirror that no longer exist in source directory
                            if let destContents = try? self.fileManager.contentsOfDirectory(at: destFileURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                                for destItem in destContents {
                                    let itemName = destItem.lastPathComponent
                                    if self.shouldIgnore(filename: itemName) { continue }
                                    let correspondingSrcURL = url.appendingPathComponent(itemName)
                                    if !self.fileManager.fileExists(atPath: correspondingSrcURL.path) {
                                        let itemRel = relPath.isEmpty ? itemName : "\(relPath)/\(itemName)"
                                        let itemLogical = "\(source.name)/\(itemRel)"
                                        try? self.deleteFileFromDestination(destinationURL: destItem, logicalPath: itemLogical, sourceId: source.id)
                                        didChangeFilesystem = true
                                    }
                                }
                            }
                        }
                        
                        // Recursively scan newly created/modified directory to catch all nested files and bundles
                        if let enumerator = self.fileManager.enumerator(
                            at: url,
                            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                            options: [.skipsHiddenFiles]
                        ) {
                            while let subURL = enumerator.nextObject() as? URL {
                                let subName = subURL.lastPathComponent
                                guard !subName.hasPrefix("."), !self.shouldIgnore(filename: subName) else {
                                    var subIsDir: ObjCBool = false
                                    if self.fileManager.fileExists(atPath: subURL.path, isDirectory: &subIsDir), subIsDir.boolValue {
                                        enumerator.skipDescendants()
                                    }
                                    continue
                                }
                                
                                guard let (subSource, subRel) = self.resolveSource(for: subURL) else { continue }
                                if self.isPathIgnored(relPath: subRel) { continue }
                                let subDestFileURL = destBase.appendingPathComponent(subSource.name).appendingPathComponent(subRel)
                                let subLogicalPath = "\(subSource.name)/\(subRel)"
                                
                                var subIsDir: ObjCBool = false
                                if self.fileManager.fileExists(atPath: subURL.path, isDirectory: &subIsDir) {
                                    if subIsDir.boolValue {
                                        if !self.fileManager.fileExists(atPath: subDestFileURL.path) {
                                            try? self.fileManager.createDirectory(at: subDestFileURL, withIntermediateDirectories: true)
                                            didChangeFilesystem = true
                                        }
                                        continue
                                    }
                                    
                                    // Regular file inside directory
                                    let attrs = try? self.fileManager.attributesOfItem(atPath: subURL.path)
                                    let currentSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                                    let currentMtime = (attrs?[.modificationDate] as? Date) ?? Date()
                                    
                                    if self.shouldIgnoreHandledEvent(logicalPath: subLogicalPath, currentSize: currentSize, currentMtime: currentMtime) {
                                        continue
                                    }
                                    
                                    if let destAttrs = try? self.fileManager.attributesOfItem(atPath: subDestFileURL.path) {
                                        let destSize = (destAttrs[.size] as? NSNumber)?.int64Value ?? 0
                                        let destMtime = (destAttrs[.modificationDate] as? Date) ?? Date.distantPast
                                        if destSize == currentSize && abs(destMtime.timeIntervalSince(currentMtime)) < 2.0 {
                                            continue
                                        }
                                    }
                                    
                                    itemsToSync.append(PendingSyncItem(
                                        sourceURL: subURL,
                                        destinationURL: subDestFileURL,
                                        logicalPath: subLogicalPath,
                                        sourceId: subSource.id
                                    ))
                                }
                            }
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
                            let destFileExists = self.fileManager.fileExists(atPath: destFileURL.path)
                            if destFileExists || (try? self.database.latestVersion(for: logicalPath, sourceId: source.id)) != nil {
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
                    didChangeFilesystem = true
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
                self.flushLiveSyncProgress()
                self.database.flushIndex()
                
                await MainActor.run {
                    self.historyRevision += 1
                    self.engineState = .idle
                    self.syncProgress.isSyncing = false
                    self.syncProgress.statusDescription = "Idle — Everything up to date"
                }
            } else {
                let changed = didChangeFilesystem
                await MainActor.run {
                    if changed {
                        self.historyRevision += 1
                    }
                    self.engineState = .idle
                    self.syncProgress.isSyncing = false
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
        sourceId: UUID,
        iCloudTimeoutSeconds: TimeInterval = 45.0
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
            // Fast skip: If destination already exists with data, no need to download from iCloud
            if fileManager.fileExists(atPath: destinationURL.path) {
                let destAttrs = try? fileManager.attributesOfItem(atPath: destinationURL.path)
                let destSize = (destAttrs?[.size] as? NSNumber)?.int64Value ?? 0
                if destSize > 0 {
                    self.markPathHandled(logicalPath: logicalPath, size: destSize, mtime: now)
                    try? database.updateJournalState(id: journalId, state: .committed)
                    return
                }
            }
            
            await MainActor.run {
                self.syncProgress.statusDescription = "Downloading \(originalFilename) from iCloud..."
            }
            iCloudState = await self.iCloudManager.ensureFileDownloaded(at: sourceURL, timeoutSeconds: iCloudTimeoutSeconds)
            
            if iCloudState == .failed {
                try database.updateJournalState(id: journalId, state: .failed)
                print("iCloud file download pending/deferred for: \(sourceURL.lastPathComponent)")
                return
            }
        }
        
        try database.updateJournalState(id: journalId, state: .copying)
        
        // 3. Conflict Protection & Prior Version Preservation
        let latestVersion = try database.latestVersion(for: logicalPath, sourceId: sourceId)
        var archivedHistorySize: Int64 = 0
        
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
            
            // Only archive prior version if this file has already been synced before (latestVersion != nil).
            // During 1st time syncing, do NOT take history or create .backup archives; leave it as live initial version.
            if let prior = latestVersion, prior.changeType != .deleted {
                let isExternalDestinationEdit = (destSHA != nil && destSHA != prior.sha256 && destSHA != sourceSHA)
                if isExternalDestinationEdit || (destSHA != nil && destSHA != sourceSHA) {
                    let (relHistPath, histSHA, histSize) = try storageManager.archiveVersion(
                        sourceFileURL: destinationURL,
                        logicalPath: logicalPath,
                        timestamp: destModDate,
                        database: database
                    )
                    archivedHistorySize = histSize
                    
                    try database.markPreviousVersionsNotCurrent(logicalPath: logicalPath, sourceId: sourceId, archivePathForLastCurrent: relHistPath)
                    
                    if isExternalDestinationEdit {
                        let priorVerNum = try database.nextVersionNumber(for: logicalPath, sourceId: sourceId)
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
                        print("SyncEngine: Conflict protected — external destination modification preserved in history.")
                    }
                }
            }
        }
        
        try database.updateJournalState(id: journalId, state: .verifying)
        
        // 4. Mirror to external destination: Real/live data sits directly in the destination mirror
        let (mirrorSHA, mirrorSize) = try storageManager.atomicMirrorCopy(
            sourceFileURL: sourceURL,
            destinationFileURL: destinationURL
        )
        
        let expectedSourceSize = (try? fileManager.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? mirrorSize
        guard mirrorSize == expectedSourceSize else {
            try database.updateJournalState(id: journalId, state: .failed)
            throw StorageError.verificationFailed("Mirror copy verification mismatch")
        }
        
        // 5. Record current live version in database (active data is in mirror, not duplicated in .backup)
        try database.markPreviousVersionsNotCurrent(logicalPath: logicalPath, sourceId: sourceId)
        let isInitialSync = (latestVersion == nil || latestVersion?.changeType == .deleted)
        let currentVerNum = isInitialSync ? 1 : try database.nextVersionNumber(for: logicalPath, sourceId: sourceId)
        
        let newEntry = FileHistoryEntry(
            sourceId: sourceId,
            logicalPath: logicalPath,
            originalFilename: originalFilename,
            timestamp: now,
            changeType: isInitialSync ? .created : .modified,
            fileSize: mirrorSize,
            sha256: mirrorSHA,
            historyRelativePath: "", // Live active file is at destinationURL, not duplicated in .backup
            isCurrentVersion: true,
            versionNumber: currentVerNum
        )
        try database.insert(version: newEntry)
        
        // 6. Mark Journal operation as committed
        try database.updateJournalState(id: journalId, state: .committed)
        
        self.markPathHandled(logicalPath: logicalPath, size: mirrorSize, mtime: now)
        self.storageMetrics.updateCachedSizes(syncedDelta: mirrorSize, historyDelta: archivedHistorySize)
        self.recordLiveSyncProgress(bytes: mirrorSize, isNewFile: !destExists)
        
        // 7. Safe iCloud Eviction: ONLY after external backup is verified!
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
        
        var isDestDir: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDestDir) {
            if isDestDir.boolValue {
                // Before removing directory, recursively find all regular files inside it and archive each to history
                if let enumerator = fileManager.enumerator(
                    at: destinationURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) {
                    let destPathPrefix = destinationURL.path
                    while let subURL = enumerator.nextObject() as? URL {
                        var isSubDir: ObjCBool = false
                        guard fileManager.fileExists(atPath: subURL.path, isDirectory: &isSubDir), !isSubDir.boolValue else { continue }
                        let subPath = subURL.path
                        if subPath.hasPrefix(destPathPrefix) {
                            var relInside = String(subPath.dropFirst(destPathPrefix.count))
                            if relInside.hasPrefix("/") { relInside.removeFirst() }
                            let subLogicalPath = "\(logicalPath)/\(relInside)"
                            let subFilename = subURL.lastPathComponent
                            
                            if let (relHistPath, histSHA, histSize) = try? storageManager.archiveVersion(
                                sourceFileURL: subURL,
                                logicalPath: subLogicalPath,
                                timestamp: now,
                                database: database
                            ) {
                                try? database.markPreviousVersionsNotCurrent(logicalPath: subLogicalPath, sourceId: sourceId)
                                if let delVerNum = try? database.nextVersionNumber(for: subLogicalPath, sourceId: sourceId) {
                                    let deleteEntry = FileHistoryEntry(
                                        sourceId: sourceId,
                                        logicalPath: subLogicalPath,
                                        originalFilename: subFilename,
                                        timestamp: now,
                                        changeType: .deleted,
                                        fileSize: histSize,
                                        sha256: histSHA,
                                        historyRelativePath: relHistPath,
                                        isCurrentVersion: false,
                                        versionNumber: delVerNum
                                    )
                                    try? database.insert(version: deleteEntry)
                                }
                            }
                        }
                    }
                }
                
                try fileManager.removeItem(at: destinationURL)
                try? database.markPreviousVersionsNotCurrent(logicalPath: logicalPath, sourceId: sourceId)
                if let delVerNum = try? database.nextVersionNumber(for: logicalPath, sourceId: sourceId) {
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
                    try? database.insert(version: deleteEntry)
                }
            } else {
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
            }
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
    
    /// Instantaneous APFS clonefile when available, falling back to standard copy.
    private func copyOrClone(from sourceURL: URL, to destURL: URL) throws {
        let srcStd = sourceURL.standardizedFileURL.path
        let dstStd = destURL.standardizedFileURL.path
        if srcStd == dstStd {
            return
        }
        
        if fileManager.fileExists(atPath: dstStd) {
            try? fileManager.removeItem(atPath: dstStd)
        }
        
        #if canImport(Darwin)
        if Darwin.clonefile(srcStd, dstStd, 0) == 0 {
            return
        }
        #endif
        
        try fileManager.copyItem(atPath: srcStd, toPath: dstStd)
    }
    
    /// Removes empty subdirectories bottom-up.
    private func removeEmptySubdirectories(at url: URL) {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        
        var subdirs: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                subdirs.append(fileURL)
            }
        }
        
        subdirs.sort(by: { $0.path.count > $1.path.count })
        for dir in subdirs {
            if let contents = try? fileManager.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? fileManager.removeItem(at: dir)
            }
        }
    }
    
    /// Robust multi-tier resolver to locate the physical file for any historical entry.
    public func resolveHistoricalFileURL(for entry: FileHistoryEntry, snapshotDate: Date? = nil) -> URL? {
        let fm = fileManager
        let historyBase = config.effectiveHistoryURL ?? storageManager.historyBaseURL
        
        // 1. Direct historyRelativePath if non-empty
        if !entry.historyRelativePath.isEmpty {
            let u = historyBase.appendingPathComponent(entry.historyRelativePath)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
                return u
            }
        }
        
        // 2. Specific snapshot folder if snapshotDate provided: snapshots/<yyyy-MM-dd_HH-mm-ss>/<logicalPath>
        if let sDate = snapshotDate {
            let folderName = storageManager.snapshotFolderName(for: sDate)
            let snapPath = "snapshots/\(folderName)/\(entry.logicalPath)"
            let u = historyBase.appendingPathComponent(snapPath)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
                return u
            }
        }
        
        // 3. Search database versions for this logicalPath
        if let allVersions = try? database.history(for: entry.logicalPath) {
            for v in allVersions where !v.historyRelativePath.isEmpty && v.changeType != .deleted {
                let u = historyBase.appendingPathComponent(v.historyRelativePath)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
                    if !entry.sha256.isEmpty && v.sha256 == entry.sha256 {
                        return u
                    }
                }
            }
            for v in allVersions where !v.historyRelativePath.isEmpty && v.changeType != .deleted {
                let u = historyBase.appendingPathComponent(v.historyRelativePath)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
                    return u
                }
            }
        }
        
        // 4. Scan physical snapshot directories on disk
        let snapshotsDir = historyBase.appendingPathComponent("snapshots", isDirectory: true)
        if let snapFolders = try? fm.contentsOfDirectory(atPath: snapshotsDir.path) {
            for folderName in snapFolders.sorted(by: >) {
                let candidate = snapshotsDir.appendingPathComponent(folderName).appendingPathComponent(entry.logicalPath)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue {
                    return candidate
                }
            }
        }
        
        // 5. Active external mirror destination (e.g. /Volumes/SanDisk/Documents/...)
        if let dest = config.syncDestination {
            let mirrorFile = dest.appendingPathComponent(entry.logicalPath)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: mirrorFile.path, isDirectory: &isDir), !isDir.boolValue {
                return mirrorFile
            }
        }
        
        // 6. Live Mac source directory
        if let source = config.sources.first(where: { $0.id == entry.sourceId }) ?? config.sources.first(where: { entry.logicalPath.hasPrefix($0.name + "/") || entry.logicalPath == $0.name }) {
            let prefix = source.name + "/"
            let rel = entry.logicalPath.hasPrefix(prefix) ? String(entry.logicalPath.dropFirst(prefix.count)) : entry.logicalPath
            let srcFile = source.url.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: srcFile.path, isDirectory: &isDir), !isDir.boolValue {
                return srcFile
            }
        }
        
        return nil
    }
    
    public func restoreVersion(entry: FileHistoryEntry, toTargetURL: URL? = nil) async throws {
        guard let source = config.sources.first(where: { $0.id == entry.sourceId })
            ?? config.sources.first(where: { entry.logicalPath.hasPrefix($0.name + "/") || entry.logicalPath == $0.name }) else {
            throw NSError(domain: "SyncEngine", code: 404, userInfo: [NSLocalizedDescriptionKey: "Source folder not found for this version."])
        }
        
        var relPath = entry.logicalPath
        if relPath.hasPrefix(source.name + "/") {
            relPath = String(relPath.dropFirst((source.name + "/").count))
        }
        
        let targetURL = toTargetURL ?? source.url.appendingPathComponent(relPath)
        
        guard let historyFileURL = resolveHistoricalFileURL(for: entry) else {
            throw StorageError.fileNotFound(entry.logicalPath)
        }
        
        await MainActor.run {
            self.isRestoring = true
            self.isQueuePaused = true
            self.engineState = .restoring
            self.restoreTitle = "Restoring \(entry.originalFilename)"
            self.restoreTotalFiles = 1
            self.restoreCurrentFile = 0
            self.restoreProgress = 0.0
            self.syncProgress.isSyncing = false
            self.syncProgress.statusDescription = "Restoring \(entry.originalFilename)..."
        }
        
        defer {
            Task { @MainActor in
                self.isRestoring = false
                self.isQueuePaused = self.isLiveSyncPaused
                self.restoreProgress = 1.0
                self.restoreCurrentFile = 1
                self.engineState = self.isLiveSyncPaused ? .paused : .idle
                self.syncProgress.statusDescription = self.isLiveSyncPaused ? "Live Sync Paused" : "Live Sync Active"
                self.historyRevision += 1
                self.refreshDiskStatus(force: true)
            }
        }
        
        let parentDir = targetURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        
        // Instant APFS clone or fast copy to Mac destination
        try copyOrClone(from: historyFileURL, to: targetURL)
        
        // Also mirror copy to external destination if configured
        if let destBase = config.syncDestination {
            let destFileURL = destBase.appendingPathComponent(source.name).appendingPathComponent(relPath)
            let destParent = destFileURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: destParent.path) {
                try fileManager.createDirectory(at: destParent, withIntermediateDirectories: true)
            }
            try copyOrClone(from: historyFileURL, to: destFileURL)
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
        
        markPathHandled(logicalPath: entry.logicalPath, size: entry.fileSize, mtime: Date())
        
        await MainActor.run {
            self.restoreCurrentFile = 1
            self.restoreProgress = 1.0
            self.syncProgress.statusDescription = "Restored \(entry.originalFilename)"
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
        let total = entries.count
        
        await MainActor.run {
            self.isRestoring = true
            self.isQueuePaused = true
            self.engineState = .restoring
            self.restoreTitle = "Restoring Full Snapshot"
            self.restoreTotalFiles = total
            self.restoreCurrentFile = 0
            self.restoreProgress = 0.0
            self.syncProgress.isSyncing = false
        }
        
        defer {
            Task { @MainActor in
                self.isRestoring = false
                self.isQueuePaused = self.isLiveSyncPaused
                self.restoreProgress = 1.0
                self.restoreCurrentFile = total
                self.engineState = self.isLiveSyncPaused ? .paused : .idle
                self.syncProgress.statusDescription = self.isLiveSyncPaused ? "Live Sync Paused" : "Live Sync Active"
                self.historyRevision += 1
                self.refreshDiskStatus(force: true)
            }
        }
        
        var restoredCount = 0
        for entry in entries {
            if let backupURL = resolveHistoricalFileURL(for: entry, snapshotDate: date),
               let source = config.sources.first(where: { $0.id == entry.sourceId }) ?? config.sources.first(where: { entry.logicalPath.hasPrefix($0.name + "/") || entry.logicalPath == $0.name }) {
                let prefix = source.name + "/"
                let rel = entry.logicalPath.hasPrefix(prefix) ? String(entry.logicalPath.dropFirst(prefix.count)) : entry.logicalPath
                let targetURL = source.url.appendingPathComponent(rel)
                let parent = targetURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parent.path) {
                    try? fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                try? copyOrClone(from: backupURL, to: targetURL)
                
                if let destBase = config.syncDestination {
                    let destFileURL = destBase.appendingPathComponent(source.name).appendingPathComponent(rel)
                    let destParent = destFileURL.deletingLastPathComponent()
                    if !fileManager.fileExists(atPath: destParent.path) {
                        try? fileManager.createDirectory(at: destParent, withIntermediateDirectories: true)
                    }
                    try? copyOrClone(from: backupURL, to: destFileURL)
                }
                markPathHandled(logicalPath: entry.logicalPath, size: entry.fileSize, mtime: Date())
            }
            restoredCount += 1
            let current = restoredCount
            let prog = Double(current) / Double(total)
            await MainActor.run {
                self.restoreCurrentFile = current
                self.restoreProgress = prog
                self.syncProgress.statusDescription = "Restoring snapshot... (\(current)/\(total))"
            }
        }
        
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let dateStr = df.string(from: date)
        
        await MainActor.run {
            self.syncProgress.statusDescription = "✓ Restored snapshot (\(dateStr))"
        }
    }
    
    /// Restores all files belonging to a historical or deleted folder back to the live source folder.
    public func restoreFolder(path: String) async throws {
        let cleanPrefix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanPrefix.isEmpty else { return }
        let prefix = cleanPrefix + "/"
        let folderName = cleanPrefix.split(separator: "/").last.map(String.init) ?? cleanPrefix
        
        let allFiles = try database.allTrackedFiles(filter: .all)
        let folderFiles = allFiles.filter { $0.logicalPath.hasPrefix(prefix) }
        let total = folderFiles.count
        guard total > 0 else { return }
        
        await MainActor.run {
            self.isRestoring = true
            self.isQueuePaused = true
            self.engineState = .restoring
            self.restoreTitle = "Restoring \(folderName)"
            self.restoreTotalFiles = total
            self.restoreCurrentFile = 0
            self.restoreProgress = 0.0
            self.syncProgress.isSyncing = false
            self.syncProgress.statusDescription = "Restoring folder '\(folderName)'... (0/\(total))"
        }
        
        defer {
            Task { @MainActor in
                self.isRestoring = false
                self.isQueuePaused = self.isLiveSyncPaused
                self.restoreProgress = 1.0
                self.restoreCurrentFile = total
                self.engineState = self.isLiveSyncPaused ? .paused : .idle
                self.syncProgress.statusDescription = self.isLiveSyncPaused ? "Live Sync Paused" : "Live Sync Active"
                self.historyRevision += 1
                self.refreshDiskStatus(force: true)
            }
        }
        
        var restoredCount = 0
        for file in folderFiles {
            let vers = try database.history(for: file.logicalPath)
            if let latestNonDeleted = vers.first(where: { $0.changeType != .deleted && !$0.historyRelativePath.isEmpty }) ?? vers.first(where: { $0.changeType != .deleted }) {
                if let backupURL = resolveHistoricalFileURL(for: latestNonDeleted),
                   let source = config.sources.first(where: { $0.id == latestNonDeleted.sourceId }) ?? config.sources.first(where: { latestNonDeleted.logicalPath.hasPrefix($0.name + "/") || latestNonDeleted.logicalPath == $0.name }) {
                    let p = source.name + "/"
                    let rel = latestNonDeleted.logicalPath.hasPrefix(p) ? String(latestNonDeleted.logicalPath.dropFirst(p.count)) : latestNonDeleted.logicalPath
                    let targetURL = source.url.appendingPathComponent(rel)
                    let parent = targetURL.deletingLastPathComponent()
                    if !fileManager.fileExists(atPath: parent.path) {
                        try? fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                    }
                    try? copyOrClone(from: backupURL, to: targetURL)
                    if let destBase = config.syncDestination {
                        let destFileURL = destBase.appendingPathComponent(source.name).appendingPathComponent(rel)
                        let destParent = destFileURL.deletingLastPathComponent()
                        if !fileManager.fileExists(atPath: destParent.path) {
                            try? fileManager.createDirectory(at: destParent, withIntermediateDirectories: true)
                        }
                        try? copyOrClone(from: backupURL, to: destFileURL)
                    }
                    markPathHandled(logicalPath: latestNonDeleted.logicalPath, size: latestNonDeleted.fileSize, mtime: Date())
                }
                restoredCount += 1
                let current = restoredCount
                let prog = Double(current) / Double(total)
                await MainActor.run {
                    self.restoreCurrentFile = current
                    self.restoreProgress = prog
                    self.syncProgress.statusDescription = "Restoring folder '\(folderName)'... (\(current)/\(total))"
                }
            }
        }
        
        let count = restoredCount
        await MainActor.run {
            self.syncProgress.statusDescription = "✓ Restored folder '\(folderName)' (\(count)/\(total) files)"
        }
    }
    
    /// Restores a folder to its exact state at a specific snapshot date.
    /// Completely replaces the current folder with the restored snapshot version:
    /// 1. Deletes every file currently in the folder that does NOT exist in the snapshot.
    /// 2. Restores every single file from the backup into both the Mac folder and external mirror.
    public func restoreFolderToVersion(path: String, at snapshotDate: Date) async throws {
        let cleanPrefix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let folderName = cleanPrefix.split(separator: "/").last.map(String.init) ?? cleanPrefix
        
        guard let source = config.sources.first(where: {
            cleanPrefix == $0.name || cleanPrefix.hasPrefix($0.name + "/")
        }) else {
            throw StorageError.restoreFailed("Source directory not found for folder: \(cleanPrefix)")
        }
        
        let relInsideSource: String
        if cleanPrefix == source.name {
            relInsideSource = ""
        } else {
            relInsideSource = String(cleanPrefix.dropFirst(source.name.count + 1))
        }
        
        let localFolderURL = relInsideSource.isEmpty ? source.url : source.url.appendingPathComponent(relInsideSource)
        let mirrorFolderURL = config.syncDestination?.appendingPathComponent(cleanPrefix)
        
        // 1. Gather all files belonging to this folder at this snapshot date
        let snapshot = try database.folderSnapshot(path: cleanPrefix, at: snapshotDate)
        
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
        
        var entries = extractEntries(from: snapshot.items)
        if let physicalSnap = try? database.files(forSnapshotAt: snapshotDate) {
            for se in physicalSnap {
                if (se.logicalPath == cleanPrefix || se.logicalPath.hasPrefix(cleanPrefix + "/")) {
                    if !entries.contains(where: { $0.logicalPath == se.logicalPath }) {
                        entries.append(se)
                    }
                }
            }
        }
        
        let total = entries.count
        
        await MainActor.run {
            self.isRestoring = true
            self.isQueuePaused = true
            self.engineState = .restoring
            self.restoreTitle = "Restoring \(folderName)"
            self.restoreTotalFiles = total
            self.restoreCurrentFile = 0
            self.restoreProgress = 0.0
            self.syncProgress.isSyncing = false
            self.syncProgress.statusDescription = "Restoring '\(folderName)'... (0/\(total))"
        }
        
        defer {
            Task { @MainActor in
                self.isRestoring = false
                self.isQueuePaused = self.isLiveSyncPaused
                self.restoreProgress = 1.0
                self.restoreCurrentFile = total
                self.engineState = self.isLiveSyncPaused ? .paused : .idle
                self.syncProgress.statusDescription = self.isLiveSyncPaused ? "Live Sync Paused" : "Live Sync Active"
                self.historyRevision += 1
                self.refreshDiskStatus(force: true)
            }
        }
        
        let snapshotLogicalPaths = Set(entries.map { $0.logicalPath })
        
        // 2. Folder replacement: Delete any files currently in current folder that do not exist in the restored version
        let localStd = localFolderURL.standardizedFileURL
        if fileManager.fileExists(atPath: localStd.path) {
            let enumerator = fileManager.enumerator(
                at: localStd,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: []
            )
            var filesToDelete: [URL] = []
            while let fileURL = enumerator?.nextObject() as? URL {
                var isDir: ObjCBool = false
                let fileStd = fileURL.standardizedFileURL
                if fileManager.fileExists(atPath: fileStd.path, isDirectory: &isDir), !isDir.boolValue {
                    let subRel = String(fileStd.path.dropFirst(localStd.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let itemLogicalPath = cleanPrefix.isEmpty ? subRel : "\(cleanPrefix)/\(subRel)"
                    if !snapshotLogicalPaths.contains(itemLogicalPath) {
                        filesToDelete.append(fileStd)
                    }
                }
            }
            for fileURL in filesToDelete {
                let subRel = String(fileURL.path.dropFirst(localStd.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let itemLogicalPath = cleanPrefix.isEmpty ? subRel : "\(cleanPrefix)/\(subRel)"
                try? fileManager.removeItem(at: fileURL)
                if let mirror = mirrorFolderURL?.standardizedFileURL {
                    let mirrorFile = mirror.appendingPathComponent(subRel)
                    try? fileManager.removeItem(at: mirrorFile)
                }
                let delVerNum = (try? database.nextVersionNumber(for: itemLogicalPath, sourceId: source.id)) ?? 1
                let delEntry = FileHistoryEntry(
                    sourceId: source.id,
                    logicalPath: itemLogicalPath,
                    originalFilename: fileURL.lastPathComponent,
                    timestamp: Date(),
                    changeType: .deleted,
                    fileSize: 0,
                    sha256: "",
                    historyRelativePath: "",
                    isCurrentVersion: false,
                    versionNumber: delVerNum
                )
                try? database.insert(version: delEntry)
            }
            
            removeEmptySubdirectories(at: localStd)
        }
        
        // Also ensure mirror destination is clean of any extra files
        if let mirrorStd = mirrorFolderURL?.standardizedFileURL, fileManager.fileExists(atPath: mirrorStd.path) {
            let enumerator = fileManager.enumerator(
                at: mirrorStd,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: []
            )
            var mirrorFilesToDelete: [URL] = []
            while let fileURL = enumerator?.nextObject() as? URL {
                var isDir: ObjCBool = false
                let fileStd = fileURL.standardizedFileURL
                if fileManager.fileExists(atPath: fileStd.path, isDirectory: &isDir), !isDir.boolValue {
                    let subRel = String(fileStd.path.dropFirst(mirrorStd.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let itemLogicalPath = cleanPrefix.isEmpty ? subRel : "\(cleanPrefix)/\(subRel)"
                    if !snapshotLogicalPaths.contains(itemLogicalPath) {
                        mirrorFilesToDelete.append(fileStd)
                    }
                }
            }
            for fileURL in mirrorFilesToDelete {
                try? fileManager.removeItem(at: fileURL)
            }
            removeEmptySubdirectories(at: mirrorStd)
        }
        
        // 3. Restore every single file from the backup into the local target folder and mirror destination
        var restoredCount = 0
        for entry in entries {
            guard let backupFileURL = resolveHistoricalFileURL(for: entry, snapshotDate: snapshotDate) else {
                print("[SyncEngine] Warning: No physical backup file found for '\(entry.logicalPath)'")
                continue
            }
            
            let relPath = entry.logicalPath.hasPrefix(source.name + "/") ? String(entry.logicalPath.dropFirst(source.name.count + 1)) : entry.logicalPath
            let targetURL = source.url.appendingPathComponent(relPath)
            let parentDir = targetURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            
            do {
                try copyOrClone(from: backupFileURL, to: targetURL)
                
                if let destBase = config.syncDestination {
                    let destFileURL = destBase.appendingPathComponent(source.name).appendingPathComponent(relPath)
                    let destParent = destFileURL.deletingLastPathComponent()
                    if !fileManager.fileExists(atPath: destParent.path) {
                        try fileManager.createDirectory(at: destParent, withIntermediateDirectories: true)
                    }
                    try copyOrClone(from: backupFileURL, to: destFileURL)
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
                markPathHandled(logicalPath: entry.logicalPath, size: entry.fileSize, mtime: Date())
                
                restoredCount += 1
                let current = restoredCount
                let prog = total > 0 ? Double(current) / Double(total) : 1.0
                await MainActor.run {
                    self.restoreCurrentFile = current
                    self.restoreProgress = prog
                    self.syncProgress.statusDescription = "Restoring '\(folderName)'... (\(current)/\(total))"
                }
            } catch {
                print("[SyncEngine] Failed to restore file '\(entry.logicalPath)': \(error)")
            }
        }
        
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let dateStr = df.string(from: snapshotDate)
        let finalCount = restoredCount
        
        await MainActor.run {
            self.syncProgress.statusDescription = "✓ Restored '\(folderName)' to \(dateStr) (\(finalCount)/\(total) files)"
        }
    }
    
    // MARK: - Reconciliation Scan (Authoritative Source of Truth)
    
    /// Periodically checks (every 5s, ~0% CPU) whether the destination mirror folders still exist.
    /// If the user manually empties the disk, formats it, or deletes a mirror folder in Finder,
    /// this automatically triggers recovery reconciliation to re-mirror all missing files.
    public func checkDestinationMirrorHealth() {
        guard isEngineActive, !isQueuePaused, !isReconciling, !isRestoring, !isLiveSyncPaused else { return }
        guard let destBase = config.syncDestination, diskMonitor.isConnected else { return }
        let activeSources = config.sources.filter { $0.isEnabled }
        guard !activeSources.isEmpty else { return }
        
        let missingSources = activeSources.filter { source in
            !fileManager.fileExists(atPath: destBase.appendingPathComponent(source.name).path)
        }
        
        if !missingSources.isEmpty {
            print("SyncEngine: Detected missing destination folders \(missingSources.map { $0.name }). Recovering mirror...")
            self.database.reloadFromStorage()
            self.triggerReconcile()
        }
    }
    
    /// Tracks iCloud files skipped during reconcile so we can auto-retry once they download.
    private var iCloudSkippedCount: Int = 0
    
    public func triggerReconcile() {
        diskMonitor.checkStatus(forceNotify: false)
        guard config.isSyncEnabled, diskMonitor.isConnected, !isReconciling, !isRestoring, !isLiveSyncPaused else { return }
        self.isQueuePaused = self.isLiveSyncPaused
        
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self, !self.isReconciling, !self.isRestoring, !self.isLiveSyncPaused else { return }
            self.isReconciling = true
            self.iCloudSkippedCount = 0
            
            await MainActor.run {
                self.engineState = .scanning
                self.syncProgress.isSyncing = true
                self.syncProgress.statusDescription = "Scanning and indexing files..."
                self.lastErrorMessage = nil
            }
            
            await self.reconcileAllSourcesInternal()
            
            let skipped = self.iCloudSkippedCount
            await MainActor.run {
                self.engineState = self.isLiveSyncPaused ? .paused : (skipped > 0 ? .copying : .idle)
                self.syncProgress.isSyncing = skipped > 0
                self.syncProgress.filesPending = skipped
                if skipped > 0 {
                    self.syncProgress.statusDescription = "Downloading \(skipped) file\(skipped == 1 ? "" : "s") from iCloud..."
                } else {
                    self.syncProgress.statusDescription = self.isLiveSyncPaused ? "Live Sync Paused" : "Idle — Everything up to date"
                    self.syncProgress.filesCompleted = 0
                    self.syncProgress.currentFileName = ""
                }
                self.syncProgress.lastSyncDate = Date()
                self.isReconciling = false
                self.lastErrorMessage = nil
            }
            self.refreshDiskStatus(force: false)
            
            // If iCloud files are still downloading, fast-retry after 5s without dropping out to idle
            if skipped > 0, !self.isLiveSyncPaused, self.diskMonitor.isConnected {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !self.isReconciling, !self.isLiveSyncPaused, self.diskMonitor.isConnected else { return }
                await MainActor.run { self.triggerReconcile() }
            }
        }
    }
    
    private func reconcileAllSourcesInternal() async {
        guard let destBase = config.syncDestination else { return }
        
        for source in config.sources where source.isEnabled {
            guard !isQueuePaused, !isRestoring, !isLiveSyncPaused else { return }
            guard fileManager.fileExists(atPath: source.url.path) else { continue }
            
            var readyItems: [PendingSyncItem] = []
            var iCloudPendingItems: [PendingSyncItem] = []
            
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
                let isDataless = iCloudManager.isDatalessICloudItem(at: fileURL)
                
                if destExists {
                    let destAttrs = try? fileManager.attributesOfItem(atPath: destFileURL.path)
                    let destSize = (destAttrs?[.size] as? NSNumber)?.int64Value ?? 0
                    let destDate = destAttrs?[.modificationDate] as? Date
                    
                    // If file is dataless locally in iCloud, and ALREADY backed up to destination:
                    if isDataless {
                        if latestVersion == nil && destSize > 0 {
                            try? database.recordVersion(
                                sourceId: src.id,
                                logicalPath: logicalPath,
                                originalFilename: filename,
                                timestamp: destDate ?? Date(),
                                changeType: .created,
                                previousPath: nil,
                                fileSize: destSize,
                                sha256: "",
                                historyRelativePath: "\(src.name)/\(relPath)"
                            )
                        }
                        continue
                    }
                    
                    let srcAttrs = try? fileManager.attributesOfItem(atPath: fileURL.path)
                    let srcSize = (srcAttrs?[.size] as? NSNumber)?.int64Value ?? 0
                    let srcDate = srcAttrs?[.modificationDate] as? Date
                    
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
                
                let syncItem = PendingSyncItem(
                    sourceURL: fileURL,
                    destinationURL: destFileURL,
                    logicalPath: logicalPath,
                    sourceId: src.id
                )
                
                if isDataless {
                    // Pre-trigger download immediately with macOS!
                    iCloudManager.triggerDownload(at: fileURL)
                    iCloudPendingItems.append(syncItem)
                } else {
                    readyItems.append(syncItem)
                }
            }
            
            // Check for locally deleted files and directories on destination mirror
            let destSrcFolder = destBase.appendingPathComponent(source.name)
            if fileManager.fileExists(atPath: destSrcFolder.path),
               let destEnumerator = fileManager.enumerator(
                at: destSrcFolder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
               ) {
                var itemsToDelete: [(url: URL, rel: String)] = []
                let destSrcPath = destSrcFolder.path
                
                while let destURL = destEnumerator.nextObject() as? URL {
                    guard !isQueuePaused, !isLiveSyncPaused else { break }
                    let name = destURL.lastPathComponent
                    if shouldIgnore(filename: name) {
                        var isD: ObjCBool = false
                        if fileManager.fileExists(atPath: destURL.path, isDirectory: &isD), isD.boolValue {
                            destEnumerator.skipDescendants()
                        }
                        continue
                    }
                    
                    let path = destURL.path
                    guard path.hasPrefix(destSrcPath) else { continue }
                    var rel = String(path.dropFirst(destSrcPath.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                    guard !rel.isEmpty else { continue }
                    
                    if isPathIgnored(relPath: rel) {
                        var isD: ObjCBool = false
                        if fileManager.fileExists(atPath: destURL.path, isDirectory: &isD), isD.boolValue {
                            destEnumerator.skipDescendants()
                        }
                        continue
                    }
                    
                    let expectedSrcURL = source.url.appendingPathComponent(rel)
                    if !fileManager.fileExists(atPath: expectedSrcURL.path) {
                        itemsToDelete.append((destURL, rel))
                        var isD: ObjCBool = false
                        if fileManager.fileExists(atPath: destURL.path, isDirectory: &isD), isD.boolValue {
                            destEnumerator.skipDescendants()
                        }
                    }
                }
                
                if !itemsToDelete.isEmpty {
                    for (delURL, delRel) in itemsToDelete {
                        let logical = "\(source.name)/\(delRel)"
                        try? deleteFileFromDestination(destinationURL: delURL, logicalPath: logical, sourceId: source.id)
                    }
                    await MainActor.run {
                        self.historyRevision += 1
                    }
                }
            }
            
            let totalCount = readyItems.count + iCloudPendingItems.count
            guard totalCount > 0 else { continue }
            
            var completedCount = 0
            var lastReportDate = Date.distantPast
            let maxConcurrent = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
            
            await MainActor.run {
                self.syncProgress.filesPending = totalCount
                self.syncProgress.filesCompleted = 0
                self.syncProgress.statusDescription = "Syncing \(source.name) (\(totalCount) files)..."
            }
            
            // Phase 1: Sync all ready local files with maximum concurrency!
            if !readyItems.isEmpty {
                await withTaskGroup(of: Void.self) { group in
                    var inFlight = 0
                    for item in readyItems {
                        guard !self.isQueuePaused, !self.isLiveSyncPaused else { break }
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
                        if now.timeIntervalSince(lastReportDate) >= 0.25 || completedCount == totalCount {
                            lastReportDate = now
                            let done = completedCount
                            let currentName = item.sourceURL.lastPathComponent
                            await MainActor.run {
                                self.syncProgress.filesCompleted = done
                                self.syncProgress.filesPending = max(0, totalCount - done)
                                self.syncProgress.currentFileName = currentName
                                self.syncProgress.statusDescription = "Syncing \(source.name) (\(done)/\(totalCount))..."
                            }
                        }
                    }
                    await group.waitForAll()
                }
            }
            
            // Phase 2: Process iCloud files as they arrive
            if !iCloudPendingItems.isEmpty {
                var remainingICloud = iCloudPendingItems
                let maxWaitRounds = 30 // Poll for up to ~30-45s actively
                var round = 0
                
                while !remainingICloud.isEmpty && round < maxWaitRounds {
                    guard !self.isQueuePaused, !self.isLiveSyncPaused else { break }
                    round += 1
                    
                    var downloadedNow: [PendingSyncItem] = []
                    var stillPending: [PendingSyncItem] = []
                    
                    for item in remainingICloud {
                        if !self.iCloudManager.isDatalessICloudItem(at: item.sourceURL) {
                            downloadedNow.append(item)
                        } else {
                            stillPending.append(item)
                        }
                    }
                    
                    if !downloadedNow.isEmpty {
                        await withTaskGroup(of: Void.self) { group in
                            var inFlight = 0
                            for item in downloadedNow {
                                guard !self.isQueuePaused, !self.isLiveSyncPaused else { break }
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
                                        print("iCloud item sync error for \(item.logicalPath): \(error)")
                                    }
                                }
                                
                                completedCount += 1
                                let now = Date()
                                if now.timeIntervalSince(lastReportDate) >= 0.25 || completedCount == totalCount {
                                    lastReportDate = now
                                    let done = completedCount
                                    let currentName = item.sourceURL.lastPathComponent
                                    await MainActor.run {
                                        self.syncProgress.filesCompleted = done
                                        self.syncProgress.filesPending = max(0, totalCount - done)
                                        self.syncProgress.currentFileName = currentName
                                        self.syncProgress.statusDescription = "Syncing \(source.name) (\(done)/\(totalCount))..."
                                    }
                                }
                            }
                            await group.waitForAll()
                        }
                    }
                    
                    remainingICloud = stillPending
                    if remainingICloud.isEmpty {
                        break
                    }
                    
                    let remCount = remainingICloud.count
                    await MainActor.run {
                        self.syncProgress.statusDescription = "Downloading \(remCount) files from iCloud..."
                    }
                    
                    // Re-trigger downloads in case macOS paused any
                    if round % 5 == 0 {
                        for item in remainingICloud {
                            self.iCloudManager.triggerDownload(at: item.sourceURL)
                        }
                    }
                    
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }
                
                if !remainingICloud.isEmpty {
                    self.iCloudSkippedCount += remainingICloud.count
                }
            }
            
            self.flushLiveSyncProgress()
            self.database.flushIndex()
            await MainActor.run {
                self.historyRevision += 1
            }
        }
    }
    
    // MARK: - Path Resolving Helpers
    
    public static let ignoredFolderNames: Set<String> = [
        "node_modules", ".git", ".build", "DerivedData", "Pods", "__pycache__", ".next", ".nuxt", ".cache", ".turbo", ".venv", "venv"
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
    /// Checks sync mirror destination on external drive first, then live source folders, then history store.
    public func resolveURL(for logicalPath: String) -> URL? {
        let fm = FileManager.default
        
        // 1. Check mirror destination (e.g. /Volumes/SanDisk/Documents/...)
        if let dest = config.syncDestination {
            let u = dest.appendingPathComponent(logicalPath)
            if fm.fileExists(atPath: u.path) {
                return u
            }
        }
        
        // 2. Check live source directories
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
        
        // 3. Check history store
        let historyBase = config.effectiveHistoryURL ?? storageManager.historyBaseURL
        let directHist = historyBase.appendingPathComponent(logicalPath)
        if fm.fileExists(atPath: directHist.path) {
            return directHist
        }
        
        // 4. Check historical snapshot versions in database (find the most recent existing snapshot file)
        if let versions = try? database.history(for: logicalPath) {
            for ver in versions where !ver.historyRelativePath.isEmpty {
                let snapURL = storageManager.historyBaseURL.appendingPathComponent(ver.historyRelativePath)
                if fm.fileExists(atPath: snapURL.path) {
                    return snapURL
                }
            }
        }
        
        // 5. If it is a folder, check if it exists in any snapshot directory
        let snapshotsDir = historyBase.appendingPathComponent("snapshots", isDirectory: true)
        if let snapFolders = try? fm.contentsOfDirectory(atPath: snapshotsDir.path) {
            for snapName in snapFolders.sorted(by: >) {
                let candidate = snapshotsDir.appendingPathComponent(snapName).appendingPathComponent(logicalPath)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                    return candidate
                }
            }
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
