import Foundation

public struct TrackedFileInfo: Identifiable, Hashable, Sendable {
    public var id: String { logicalPath }
    public let logicalPath: String
    public let originalFilename: String
    public let lastChangeType: ChangeType
    public let lastTimestamp: Date
    public let fileSize: Int64
    public let versionCount: Int
    public let isDeleted: Bool
    /// True if at least one version record has a physical archive copy in .backup (historyRelativePath != "")
    public let hasArchivedVersion: Bool
    
    public var filename: String { originalFilename }
    public var isCurrentDeleted: Bool { isDeleted }
    
    public init(
        logicalPath: String,
        originalFilename: String,
        lastChangeType: ChangeType,
        lastTimestamp: Date,
        fileSize: Int64,
        versionCount: Int,
        isDeleted: Bool,
        hasArchivedVersion: Bool = false
    ) {
        self.logicalPath = logicalPath
        self.originalFilename = originalFilename
        self.lastChangeType = lastChangeType
        self.lastTimestamp = lastTimestamp
        self.fileSize = fileSize
        self.versionCount = versionCount
        self.isDeleted = isDeleted
        self.hasArchivedVersion = hasArchivedVersion
    }
}

public struct FolderHistoryVersion: Identifiable, Hashable, Sendable {
    public var id: String { "\(path)_\(versionNumber)" }
    public let path: String
    public let name: String
    public let timestamp: Date
    public let changeType: ChangeType
    public let itemCount: Int
    public let versionNumber: Int
    public let isCurrentVersion: Bool
    
    public init(
        path: String,
        name: String,
        timestamp: Date,
        changeType: ChangeType,
        itemCount: Int,
        versionNumber: Int,
        isCurrentVersion: Bool
    ) {
        self.path = path
        self.name = name
        self.timestamp = timestamp
        self.changeType = changeType
        self.itemCount = itemCount
        self.versionNumber = versionNumber
        self.isCurrentVersion = isCurrentVersion
    }
}

public enum FileFilter: String, CaseIterable, Sendable {
    case all = "All Files"
    case active = "Active"
    case deleted = "Deleted"
}

public struct ContentObject: Sendable {
    public let sha256: String
    public let size: Int64
    public let storagePath: String
    public let refCount: Int
    public let createdAt: Date
    
    public init(sha256: String, size: Int64, storagePath: String, refCount: Int = 1, createdAt: Date = Date()) {
        self.sha256 = sha256
        self.size = size
        self.storagePath = storagePath
        self.refCount = refCount
        self.createdAt = createdAt
    }
}

public enum JournalState: String, Sendable, Codable {
    case pending = "pending"
    case copying = "copying"
    case verifying = "verifying"
    case committed = "committed"
    case failed = "failed"
}

public struct JournalEntry: Identifiable, Sendable, Codable {
    public let id: UUID
    public let opType: String
    public let sourcePath: String
    public let destinationPath: String
    public let logicalPath: String
    public var state: JournalState
    public let createdAt: Date
    public var updatedAt: Date
    
    public init(id: UUID, opType: String, sourcePath: String, destinationPath: String, logicalPath: String, state: JournalState, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.opType = opType
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.logicalPath = logicalPath
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Pure File-Based History Engine (No SQLite, No Local DB, 100% Storage-to-Storage)

public final class HistoryDatabase: @unchecked Sendable {
    public let databaseURL: URL
    public let storageBaseURL: URL
    
    private let queue = DispatchQueue(label: "com.syncdisk.filebasedhistory", qos: .userInitiated)
    private let fileManager = FileManager.default
    
    // In-memory indexing structures updated directly from and saved to storage files
    private var versionsByPath: [String: [FileHistoryEntry]] = [:]
    private var snapshotsByDate: [Date: [FileHistoryEntry]] = [:]
    private var journals: [UUID: JournalEntry] = [:]
    
    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
        // If databaseURL points to a file (e.g. legacy history.sqlite), resolve to parent directory
        if databaseURL.pathExtension.isEmpty {
            self.storageBaseURL = databaseURL
        } else {
            self.storageBaseURL = databaseURL.deletingPathExtension()
        }
        
        guard !HistoryStorageManager.isForbiddenInternalStorage(url: storageBaseURL) else {
            print("SyncDisk Error: Prohibited attempt to initialize HistoryDatabase on internal storage: \(storageBaseURL.path)")
            return
        }
        
        if fileManager.fileExists(atPath: storageBaseURL.deletingLastPathComponent().path) {
            try? ensureDirectoryExists(at: storageBaseURL.appendingPathComponent("snapshots", isDirectory: true))
            let neverIndex = storageBaseURL.appendingPathComponent(".metadata_never_index")
            if !fileManager.fileExists(atPath: neverIndex.path) {
                try? Data().write(to: neverIndex)
            }
        }
        scanSnapshotsFromStorage()
    }
    
    public init(storageBaseURL: URL) {
        self.databaseURL = storageBaseURL
        self.storageBaseURL = storageBaseURL
        
        guard !HistoryStorageManager.isForbiddenInternalStorage(url: storageBaseURL) else {
            print("SyncDisk Error: Prohibited attempt to initialize HistoryDatabase on internal storage: \(storageBaseURL.path)")
            return
        }
        
        if fileManager.fileExists(atPath: storageBaseURL.deletingLastPathComponent().path) {
            try? ensureDirectoryExists(at: storageBaseURL.appendingPathComponent("snapshots", isDirectory: true))
            let neverIndex = storageBaseURL.appendingPathComponent(".metadata_never_index")
            if !fileManager.fileExists(atPath: neverIndex.path) {
                try? Data().write(to: neverIndex)
            }
        }
        scanSnapshotsFromStorage()
    }
    
    private func ensureDirectoryExists(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
    
    private var indexFileURL: URL {
        storageBaseURL.appendingPathComponent("history_index.json")
    }
    
    private var isDirty = false
    private var scheduledFlushWorkItem: DispatchWorkItem?
    
    public func flushIndex() {
        queue.sync {
            flushIndexLocked()
        }
    }
    
    private func flushIndexLocked() {
        scheduledFlushWorkItem?.cancel()
        scheduledFlushWorkItem = nil
        guard isDirty else { return }
        guard !HistoryStorageManager.isForbiddenInternalStorage(url: storageBaseURL) else { return }
        isDirty = false
        if let data = try? JSONEncoder().encode(versionsByPath) {
            try? data.write(to: indexFileURL, options: .atomic)
        }
    }
    
    private func saveIndexToStorageLocked() {
        isDirty = true
        scheduledFlushWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.queue.sync {
                self?.flushIndexLocked()
            }
        }
        scheduledFlushWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    
    private var isIndexLoaded = false
    
    // MARK: - Filesystem Snapshot Scanner & Indexer
    
    public func reloadFromStorage() {
        queue.sync {
            scanSnapshotsFromStorageLocked(force: false)
        }
    }
    
    public func reloadFromStorageIfNeeded() {
        queue.sync {
            if !isIndexLoaded || versionsByPath.isEmpty {
                scanSnapshotsFromStorageLocked(force: false)
            }
        }
    }
    
    public func scanSnapshotsFromStorage() {
        queue.sync {
            scanSnapshotsFromStorageLocked(force: true)
        }
    }
    
    private func scanSnapshotsFromStorageLocked(force: Bool = false) {
        if !force && isIndexLoaded && !versionsByPath.isEmpty {
            return
        }
        
        // 1. First check if persistent history_index.json already exists on storageBaseURL,
        // but ONLY if the snapshots directory actually exists physically on disk.
        let snapshotsDir = storageBaseURL.appendingPathComponent("snapshots", isDirectory: true)
        if fileManager.fileExists(atPath: snapshotsDir.path),
           let data = try? Data(contentsOf: indexFileURL),
           let decoded = try? JSONDecoder().decode([String: [FileHistoryEntry]].self, from: data),
           !decoded.isEmpty {
            self.versionsByPath = decoded
            self.isIndexLoaded = true
            return
        }
        
        guard fileManager.fileExists(atPath: snapshotsDir.path),
              let folderNames = try? fileManager.contentsOfDirectory(atPath: snapshotsDir.path), !folderNames.isEmpty else {
            self.versionsByPath = [:]
            self.snapshotsByDate = [:]
            self.isIndexLoaded = true
            return
        }
            
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            df.timeZone = TimeZone.current
            
            var newVersionsByPath: [String: [FileHistoryEntry]] = [:]
            var newSnapshotsByDate: [Date: [FileHistoryEntry]] = [:]
            
            // Sort snapshot folders chronologically
            let sortedFolders = folderNames.sorted()
            
            for folderName in sortedFolders {
                guard let snapDate = df.date(from: folderName) else { continue }
                let folderURL = snapshotsDir.appendingPathComponent(folderName, isDirectory: true)
                let manifestURL = folderURL.appendingPathComponent("manifest.json")
                
                var entriesForSnap: [FileHistoryEntry] = []
                
                // 1. Try reading manifest.json inside this snapshot folder on storage
                if let data = try? Data(contentsOf: manifestURL),
                   let decoded = try? JSONDecoder().decode([FileHistoryEntry].self, from: data) {
                    entriesForSnap = decoded
                } else {
                    // 2. Fallback: Reconstruct entries directly by enumerating files in this snapshot directory
                    if let enumerator = fileManager.enumerator(
                        at: folderURL,
                        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                        options: [.skipsHiddenFiles]
                    ) {
                        for case let fileURL as URL in enumerator {
                            if fileURL.lastPathComponent == "manifest.json" { continue }
                            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                            
                            let relFromSnap = String(fileURL.path.dropFirst(folderURL.path.count + 1))
                            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                            let originalName = fileURL.lastPathComponent
                            let relInsideHistory = "snapshots/\(folderName)/\(relFromSnap)"
                            
                            let entry = FileHistoryEntry(
                                id: UUID(),
                                sourceId: UUID(),
                                logicalPath: relFromSnap,
                                originalFilename: originalName,
                                timestamp: snapDate,
                                changeType: .modified,
                                previousPath: nil,
                                fileSize: Int64(size),
                                sha256: "",
                                historyRelativePath: relInsideHistory,
                                isCurrentVersion: true,
                                versionNumber: 1
                            )
                            entriesForSnap.append(entry)
                        }
                    }
                    
                    // Persist manifest.json to avoid re-enumerating next time
                    if !entriesForSnap.isEmpty {
                        if let encoded = try? JSONEncoder().encode(entriesForSnap) {
                            try? encoded.write(to: manifestURL, options: .atomic)
                        }
                    }
                }
                
                newSnapshotsByDate[snapDate] = entriesForSnap
                
                for entry in entriesForSnap {
                    newVersionsByPath[entry.logicalPath, default: []].append(entry)
                }
            }
            
            // Mark the latest version of each path as isCurrentVersion = true and update version numbers
            for (path, list) in newVersionsByPath {
                let sortedList = list.sorted(by: { $0.timestamp < $1.timestamp })
                var numberedList: [FileHistoryEntry] = []
                for (idx, var item) in sortedList.enumerated() {
                    item.versionNumber = idx + 1
                    item.isCurrentVersion = (idx == sortedList.count - 1)
                    numberedList.append(item)
                }
                newVersionsByPath[path] = numberedList
            }
            
            self.versionsByPath = newVersionsByPath
            self.snapshotsByDate = newSnapshotsByDate
            self.saveIndexToStorageLocked()
    }
    
    // MARK: - Version Operations
    
    public func nextVersionNumber(for logicalPath: String, sourceId: UUID) throws -> Int {
        return queue.sync {
            let list = versionsByPath[logicalPath] ?? []
            return (list.map(\.versionNumber).max() ?? 0) + 1
        }
    }
    
    public func latestVersion(for logicalPath: String, sourceId: UUID) throws -> FileHistoryEntry? {
        return queue.sync {
            guard let list = versionsByPath[logicalPath], !list.isEmpty else { return nil }
            return list.sorted(by: { $0.timestamp > $1.timestamp }).first
        }
    }
    
    public func markPreviousVersionsNotCurrent(logicalPath: String, sourceId: UUID, archivePathForLastCurrent: String? = nil) throws {
        queue.sync {
            guard var list = versionsByPath[logicalPath] else { return }
            for i in 0..<list.count {
                if list[i].isCurrentVersion {
                    list[i].isCurrentVersion = false
                    if let archivePath = archivePathForLastCurrent, list[i].historyRelativePath.isEmpty {
                        list[i].historyRelativePath = archivePath
                    }
                }
            }
            versionsByPath[logicalPath] = list
            saveIndexToStorageLocked()
        }
    }
    
    public func insert(version: FileHistoryEntry) throws {
        try queue.sync {
            var list = versionsByPath[version.logicalPath] ?? []
            list.append(version)
            versionsByPath[version.logicalPath] = list
            saveIndexToStorageLocked()
            
            // Extract snapshot folder name from historyRelativePath
            let parts = version.historyRelativePath.split(separator: "/")
            if parts.count >= 2 && parts[0] == "snapshots" {
                let snapName = String(parts[1])
                let snapFolder = storageBaseURL
                    .appendingPathComponent("snapshots", isDirectory: true)
                    .appendingPathComponent(snapName, isDirectory: true)
                try ensureDirectoryExists(at: snapFolder)
                
                let manifestURL = snapFolder.appendingPathComponent("manifest.json")
                var snapEntries: [FileHistoryEntry] = []
                if let data = try? Data(contentsOf: manifestURL),
                   let decoded = try? JSONDecoder().decode([FileHistoryEntry].self, from: data) {
                    snapEntries = decoded.filter { $0.logicalPath != version.logicalPath }
                }
                snapEntries.append(version)
                
                if let encoded = try? JSONEncoder().encode(snapEntries) {
                    try? encoded.write(to: manifestURL, options: .atomic)
                }
                
                snapshotsByDate[version.timestamp] = snapEntries
            }
        }
    }
    
    public func recordVersion(
        sourceId: UUID,
        logicalPath: String,
        originalFilename: String,
        timestamp: Date,
        changeType: ChangeType,
        previousPath: String?,
        fileSize: Int64,
        sha256: String,
        historyRelativePath: String
    ) throws {
        let verNum = try nextVersionNumber(for: logicalPath, sourceId: sourceId)
        try markPreviousVersionsNotCurrent(logicalPath: logicalPath, sourceId: sourceId)
        
        let entry = FileHistoryEntry(
            id: UUID(),
            sourceId: sourceId,
            logicalPath: logicalPath,
            originalFilename: originalFilename,
            timestamp: timestamp,
            changeType: changeType,
            previousPath: previousPath,
            fileSize: fileSize,
            sha256: sha256,
            historyRelativePath: historyRelativePath,
            isCurrentVersion: true,
            versionNumber: verNum
        )
        try insert(version: entry)
    }
    
    public func recordDeletion(
        sourceId: UUID,
        logicalPath: String,
        originalFilename: String,
        timestamp: Date
    ) throws {
        let verNum = try nextVersionNumber(for: logicalPath, sourceId: sourceId)
        try markPreviousVersionsNotCurrent(logicalPath: logicalPath, sourceId: sourceId)
        
        let entry = FileHistoryEntry(
            id: UUID(),
            sourceId: sourceId,
            logicalPath: logicalPath,
            originalFilename: originalFilename,
            timestamp: timestamp,
            changeType: .deleted,
            previousPath: nil,
            fileSize: 0,
            sha256: "",
            historyRelativePath: "",
            isCurrentVersion: true,
            versionNumber: verNum
        )
        try insert(version: entry)
    }
    
    public func history(for logicalPath: String) throws -> [FileHistoryEntry] {
        return queue.sync {
            let list = versionsByPath[logicalPath] ?? []
            return list.sorted(by: { $0.timestamp > $1.timestamp })
        }
    }
    
    public func allTrackedFiles(filter: FileFilter) throws -> [TrackedFileInfo] {
        return try allTrackedFiles(query: nil, filter: filter)
    }
    
    /// Count of unique logical paths that have at least one physically archived copy in .backup
    /// that actually exists on disk.
    /// This is the correct value for the "History" sidebar count.
    public func countPathsWithArchivedHistory() -> Int {
        return queue.sync {
            if versionsByPath.isEmpty {
                scanSnapshotsFromStorageLocked()
            }
            return versionsByPath.values.filter { versions in
                versions.contains(where: { v in
                    guard !v.historyRelativePath.isEmpty else { return false }
                    if v.historyRelativePath.hasPrefix("snapshots/") {
                        let archiveURL = storageBaseURL.appendingPathComponent(v.historyRelativePath)
                        return fileManager.fileExists(atPath: archiveURL.path)
                    }
                    return true
                })
            }.count
        }
    }
    
    public func allTrackedFiles(query: String? = nil, filter: FileFilter = .all) throws -> [TrackedFileInfo] {
        return queue.sync {
            if versionsByPath.isEmpty {
                scanSnapshotsFromStorageLocked()
            }
            var result: [TrackedFileInfo] = []
            
            for (logicalPath, versions) in versionsByPath {
                guard let latest = versions.sorted(by: {
                    if $0.timestamp != $1.timestamp {
                        return $0.timestamp > $1.timestamp
                    }
                    return $0.versionNumber > $1.versionNumber
                }).first else {
                    continue
                }
                
                let isDeleted = (latest.changeType == .deleted)
                
                // Physical archive verification: does an archive file actually exist on disk in .backup?
                let hasArchived = versions.contains(where: { v in
                    guard !v.historyRelativePath.isEmpty else { return false }
                    if v.historyRelativePath.hasPrefix("snapshots/") {
                        let archiveURL = storageBaseURL.appendingPathComponent(v.historyRelativePath)
                        return fileManager.fileExists(atPath: archiveURL.path)
                    }
                    return true
                })
                
                // Apply filter
                switch filter {
                case .all:
                    break
                case .active:
                    if isDeleted { continue }
                case .deleted:
                    if !isDeleted { continue }
                }
                
                // Apply search query
                if let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
                    let matchesName = latest.originalFilename.localizedCaseInsensitiveContains(q)
                    let matchesPath = logicalPath.localizedCaseInsensitiveContains(q)
                    if !matchesName && !matchesPath {
                        continue
                    }
                }
                
                let info = TrackedFileInfo(
                    logicalPath: logicalPath,
                    originalFilename: latest.originalFilename,
                    lastChangeType: latest.changeType,
                    lastTimestamp: latest.timestamp,
                    fileSize: latest.fileSize,
                    versionCount: versions.count,
                    isDeleted: isDeleted,
                    hasArchivedVersion: hasArchived
                )
                result.append(info)
            }
            
            return result.sorted { a, b in
                if a.lastTimestamp != b.lastTimestamp {
                    return a.lastTimestamp > b.lastTimestamp
                }
                return a.logicalPath.localizedStandardCompare(b.logicalPath) == .orderedAscending
            }
        }
    }
    
    // MARK: - Snapshot Operations
    
    public func allSnapshots() throws -> [Date] {
        return queue.sync {
            let snapshotsDir = storageBaseURL.appendingPathComponent("snapshots", isDirectory: true)
            guard let folderNames = try? fileManager.contentsOfDirectory(atPath: snapshotsDir.path) else {
                return Array(snapshotsByDate.keys).sorted(by: >)
            }
            
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            df.timeZone = TimeZone.current
            
            var dates: [Date] = []
            for name in folderNames {
                if let d = df.date(from: name) {
                    dates.append(d)
                }
            }
            return dates.sorted(by: >)
        }
    }
    
    public func distinctDatesWithActivity(for path: String) throws -> [Date] {
        return try allSnapshots()
    }
    
    public func files(forSnapshotAt date: Date) throws -> [FileHistoryEntry] {
        return queue.sync {
            if let entries = snapshotsByDate[date] {
                return entries
            }
            // Match closest timestamp within 2 seconds
            for (d, entries) in snapshotsByDate {
                if abs(d.timeIntervalSince(date)) <= 2.0 {
                    return entries
                }
            }
            return []
        }
    }
    
    public func folderSnapshot(path: String, at date: Date) throws -> FolderSnapshot {
        return queue.sync {
            let cleanPrefix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            
            // 1. For each distinct logicalPath, find the latest version on or before 'date'
            var activeFiles: [FileHistoryEntry] = []
            
            for (logicalPath, versions) in versionsByPath {
                if !cleanPrefix.isEmpty {
                    if logicalPath != cleanPrefix && !logicalPath.hasPrefix(cleanPrefix + "/") {
                        continue
                    }
                }
                
                let validVersions = versions.filter { $0.timestamp <= date }.sorted(by: { $0.timestamp > $1.timestamp })
                guard let latest = validVersions.first else { continue }
                
                if latest.changeType != .deleted {
                    activeFiles.append(latest)
                }
            }
            
            // 2. Build folder tree hierarchy
            let items = buildSnapshotTree(for: activeFiles, relativeTo: cleanPrefix)
            
            return FolderSnapshot(
                folderLogicalPath: path,
                snapshotDate: date,
                items: items
            )
        }
    }
    
    public func versionCount(forFolder path: String) -> Int {
        return queue.sync {
            let hist = folderHistoryLocked(for: path)
            return max(1, hist.count)
        }
    }
    
    public func folderHistory(for path: String) -> [FolderHistoryVersion] {
        return queue.sync {
            return folderHistoryLocked(for: path)
        }
    }
    
    private func folderHistoryLocked(for path: String) -> [FolderHistoryVersion] {
        let cleanPrefix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanPrefix.isEmpty else { return [] }
        let prefix = cleanPrefix + "/"
        let folderName = cleanPrefix.split(separator: "/").last.map(String.init) ?? cleanPrefix
        
        var folderEntries: [FileHistoryEntry] = []
        for (logicalPath, vers) in versionsByPath where logicalPath.hasPrefix(prefix) {
            folderEntries.append(contentsOf: vers)
        }
        
        guard !folderEntries.isEmpty else {
            return [
                FolderHistoryVersion(
                    path: cleanPrefix,
                    name: folderName,
                    timestamp: Date(),
                    changeType: .created,
                    itemCount: 0,
                    versionNumber: 1,
                    isCurrentVersion: true
                )
            ]
        }
        
        let sortedEntries = folderEntries.sorted(by: { $0.timestamp < $1.timestamp })
        var distinctDates: [Date] = []
        for entry in sortedEntries {
            if let last = distinctDates.last {
                if abs(entry.timestamp.timeIntervalSince(last)) > 2.0 {
                    distinctDates.append(entry.timestamp)
                }
            } else {
                distinctDates.append(entry.timestamp)
            }
        }
        
        var result: [FolderHistoryVersion] = []
        for (idx, date) in distinctDates.enumerated() {
            let verNum = idx + 1
            var activeCount = 0
            var allDeleted = true
            for (logicalPath, vers) in versionsByPath where logicalPath.hasPrefix(prefix) {
                if let latestAtDate = vers.filter({ $0.timestamp <= date }).sorted(by: { $0.timestamp > $1.timestamp }).first {
                    if latestAtDate.changeType != .deleted {
                        activeCount += 1
                        allDeleted = false
                    }
                }
            }
            
            let changeType: ChangeType = allDeleted ? .deleted : (idx == 0 ? .created : .modified)
            let isCurrent = (idx == distinctDates.count - 1)
            
            result.append(FolderHistoryVersion(
                path: cleanPrefix,
                name: folderName,
                timestamp: date,
                changeType: changeType,
                itemCount: activeCount,
                versionNumber: verNum,
                isCurrentVersion: isCurrent
            ))
        }
        
        return result.reversed()
    }
    
    private func buildSnapshotTree(for entries: [FileHistoryEntry], relativeTo prefix: String) -> [FolderSnapshotItem] {
        var directFiles: [FolderSnapshotItem] = []
        var subfolderEntries: [String: [FileHistoryEntry]] = [:]
        
        for entry in entries {
            let rel: String
            if prefix.isEmpty {
                rel = entry.logicalPath
            } else if entry.logicalPath.hasPrefix(prefix + "/") {
                rel = String(entry.logicalPath.dropFirst(prefix.count + 1))
            } else {
                rel = entry.logicalPath
            }
            
            let parts = rel.split(separator: "/").map(String.init)
            if parts.count <= 1 {
                let item = FolderSnapshotItem(
                    name: parts.first ?? entry.originalFilename,
                    path: entry.logicalPath,
                    isDirectory: false,
                    fileEntry: entry,
                    children: []
                )
                directFiles.append(item)
            } else {
                let firstPart = parts[0]
                subfolderEntries[firstPart, default: []].append(entry)
            }
        }
        
        var folderItems: [FolderSnapshotItem] = []
        for (folderName, childEntries) in subfolderEntries {
            let subPath = prefix.isEmpty ? folderName : "\(prefix)/\(folderName)"
            let children = buildSnapshotTree(for: childEntries, relativeTo: subPath)
            let folderItem = FolderSnapshotItem(
                name: folderName,
                path: subPath,
                isDirectory: true,
                fileEntry: nil,
                children: children
            )
            folderItems.append(folderItem)
        }
        
        let sortedFolders = folderItems.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        let sortedFiles = directFiles.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        return sortedFolders + sortedFiles
    }
    
    public func restoreEntireSnapshot(at date: Date, destinationRoot: URL, storageManager: HistoryStorageManager) throws {
        let entries = try files(forSnapshotAt: date)
        for entry in entries {
            if entry.changeType == .deleted { continue }
            let sourceFile = storageManager.historyBaseURL.appendingPathComponent(entry.historyRelativePath)
            guard fileManager.fileExists(atPath: sourceFile.path) else { continue }
            
            let target = destinationRoot.appendingPathComponent(entry.logicalPath)
            try ensureDirectoryExists(at: target.deletingLastPathComponent())
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: sourceFile, to: target)
        }
    }
    
    public func registerContentObject(sha256: String, size: Int64, proposedPath: String) throws -> (isNew: Bool, object: ContentObject) {
        return queue.sync {
            let matching = versionsByPath.values.flatMap { $0 }.filter { $0.sha256 == sha256 }
            let count = max(1, matching.count)
            let obj = ContentObject(sha256: sha256, size: size, storagePath: proposedPath, refCount: count)
            return (isNew: count == 1, object: obj)
        }
    }
    
    public func getContentObject(sha256: String) throws -> ContentObject? {
        return queue.sync {
            let matching = versionsByPath.values.flatMap { $0 }.filter { $0.sha256 == sha256 }
            guard !matching.isEmpty else { return nil }
            let first = matching.first!
            return ContentObject(sha256: sha256, size: first.fileSize, storagePath: first.historyRelativePath, refCount: matching.count)
        }
    }
    
    public func pruneOldSnapshots(keepCount: Int) {
        queue.sync {
            guard let dates = try? allSnapshots(), dates.count > keepCount else { return }
            let toRemove = dates.suffix(dates.count - keepCount)
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            df.timeZone = TimeZone.current
            
            let snapshotsDir = storageBaseURL.appendingPathComponent("snapshots", isDirectory: true)
            for d in toRemove {
                let name = df.string(from: d)
                let dir = snapshotsDir.appendingPathComponent(name, isDirectory: true)
                try? fileManager.removeItem(at: dir)
                snapshotsByDate.removeValue(forKey: d)
            }
        }
    }
    
    // MARK: - Metrics and Growth
    
    public func historyCounts() throws -> (totalVersions: Int, totalFiles: Int) {
        return queue.sync {
            let totalVers = versionsByPath.values.reduce(0) { $0 + $1.count }
            let totalF = versionsByPath.keys.count
            return (totalVersions: totalVers, totalFiles: totalF)
        }
    }
    
    public func historyGrowthToday() throws -> Int64 {
        return queue.sync {
            let startOfDay = Calendar.current.startOfDay(for: Date())
            var sum: Int64 = 0
            for list in versionsByPath.values {
                for v in list where v.timestamp >= startOfDay {
                    sum += v.fileSize
                }
            }
            return sum
        }
    }
    
    public func historyGrowthThisWeek() throws -> Int64 {
        return queue.sync {
            let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            var sum: Int64 = 0
            for list in versionsByPath.values {
                for v in list where v.timestamp >= weekAgo {
                    sum += v.fileSize
                }
            }
            return sum
        }
    }
    
    public func historyGrowthThisMonth() throws -> Int64 {
        return queue.sync {
            let monthAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            var sum: Int64 = 0
            for list in versionsByPath.values {
                for v in list where v.timestamp >= monthAgo {
                    sum += v.fileSize
                }
            }
            return sum
        }
    }
    
    public func dailyHistoryGrowth(days: Int = 7) throws -> [DayGrowthItem] {
        return queue.sync {
            let calendar = Calendar.current
            let now = Date()
            var items: [DayGrowthItem] = []
            let df = DateFormatter()
            df.dateFormat = "EEE"
            
            for offset in (0..<days).reversed() {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
                let startOfDay = calendar.startOfDay(for: day)
                guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { continue }
                
                var addedBytes: Int64 = 0
                var versionCount = 0
                
                for list in versionsByPath.values {
                    for v in list where v.timestamp >= startOfDay && v.timestamp < endOfDay {
                        addedBytes += v.fileSize
                        versionCount += 1
                    }
                }
                
                let label = calendar.isDateInToday(day) ? "Today" : df.string(from: day)
                items.append(DayGrowthItem(
                    date: day,
                    dateLabel: label,
                    addedBytes: addedBytes,
                    versionCount: versionCount
                ))
            }
            return items
        }
    }
    
    // MARK: - Crash Recovery Journal (Pure In-Memory / Ephemeral)
    
    public func startJournalOperation(opType: String, sourcePath: String, destinationPath: String, logicalPath: String) throws -> UUID {
        return queue.sync {
            let id = UUID()
            let now = Date()
            let entry = JournalEntry(
                id: id,
                opType: opType,
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                logicalPath: logicalPath,
                state: .pending,
                createdAt: now,
                updatedAt: now
            )
            journals[id] = entry
            return id
        }
    }
    
    public func updateJournalState(id: UUID, state: JournalState) throws {
        queue.sync {
            guard var entry = journals[id] else { return }
            entry.state = state
            entry.updatedAt = Date()
            journals[id] = entry
            if state == .committed {
                journals.removeValue(forKey: id)
            }
        }
    }
    
    public func cleanCommittedJournalOperations() {
        queue.sync {
            journals = journals.filter { $0.value.state != .committed }
        }
    }
    
    public func uncommittedJournalOperations() throws -> [JournalEntry] {
        return queue.sync {
            Array(journals.values).filter { $0.state != .committed }
        }
    }
}
