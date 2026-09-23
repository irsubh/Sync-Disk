import SwiftUI
import AppKit

public enum FileViewLayoutMode: String, CaseIterable, Sendable {
    case icons = "Icons"
    case list = "List"
}

public enum FileSortOption: String, CaseIterable, Sendable {
    case name = "Name"
    case kind = "Kind"
    case sharedBy = "Shared By"
    case lastModifiedBy = "Last Modified By"
    case dateLastOpened = "Date Last Opened"
    case dateAdded = "Date Added"
    case dateModified = "Date Modified"
    case dateCreated = "Date Created"
    case size = "Size"
    case tags = "Tags"
}

@MainActor
public final class HistoryWindowViewModel: ObservableObject {
    @Published public var libraryFilter: HistoryLibraryFilter = .all
    @Published public var selectedSourceId: UUID? = nil
    
    public var sidebarSelection: HistorySidebarSelection {
        get {
            if let sid = selectedSourceId {
                return .source(sid)
            }
            switch libraryFilter {
            case .all: return .allFiles
            case .active: return .activeOnly
            case .history: return .deletedOnly
            }
        }
        set {
            switch newValue {
            case .allFiles:
                libraryFilter = .all
                selectedSourceId = nil
            case .activeOnly:
                libraryFilter = .active
                selectedSourceId = nil
            case .deletedOnly:
                libraryFilter = .history
                selectedSourceId = nil
            case .source(let id):
                selectedSourceId = id
            }
        }
    }
    @Published public var searchText: String = ""
    @Published public var trackedFiles: [TrackedFileInfo] = []
    @Published public var selectedFilePath: String?
    @Published public var selectedFolder: FolderDisplayItem?
    @Published public var fileVersions: [FileHistoryEntry] = []
    @Published public var selectedVersion: FileHistoryEntry?
    
    // View mode and sorting (Default: Date Modified, descending)
    @Published public var layoutMode: FileViewLayoutMode = .icons
    @Published public var sortOption: FileSortOption = .dateModified
    @Published public var sortAscending: Bool = false
    @Published public var currentFolderPath: String? = nil
    @Published public var displayedItems: [FileManagerGridItem] = []
    @Published public var knownDirectoryPaths: Set<String> = []
    
    @Published public var totalCount: Int = 0
    @Published public var activeCount: Int = 0
    @Published public var deletedCount: Int = 0
    @Published public var columnVisibility: NavigationSplitViewVisibility = .all
    
    public init() {}
    
    nonisolated public static func calculateItemSize(at url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        
        if !isDir.boolValue {
            let vals = try? url.resourceValues(forKeys: [.totalFileSizeKey, .fileSizeKey])
            return Int64(vals?.totalFileSize ?? vals?.fileSize ?? 0)
        }
        
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileSizeKey, .fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }
        
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileSizeKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let sz = Int64(values.totalFileSize ?? values.fileSize ?? 0)
            total += sz
        }
        return total
    }
    
    /// Counts all individual files across all source folders on destination disk (not just synced history).
    /// - totalCount:  all unique file paths (on destination + in history)
    /// - activeCount: files that exist on destination disk right now
    /// - deletedCount: files recorded in history but no longer on destination disk
    public func reloadCounts(database: HistoryDatabase, sources: [SyncSource] = [], destination: URL? = nil) {
        let fm = FileManager.default
        
        // Count actual files on destination disk across all enabled sources
        var liveFilePaths: Set<String> = []
        if let destBase = destination {
            for source in sources where source.isEnabled {
                let destSourceURL = destBase.appendingPathComponent(source.name)
                guard fm.fileExists(atPath: destSourceURL.path) else { continue }
                let destSrcStd = destSourceURL.standardizedFileURL.path
                let enumerator = fm.enumerator(
                    at: destSourceURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                while let url = enumerator?.nextObject() as? URL {
                    let name = url.lastPathComponent
                    // Skip hidden/system/build files
                    guard !name.hasPrefix("."),
                          !SyncEngine.ignoredFolderNames.contains(name) else {
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                            enumerator?.skipDescendants()
                        }
                        continue
                    }
                    
                    let isApp = url.pathExtension.lowercased() == "app" ||
                                (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
                    if isApp {
                        enumerator?.skipDescendants()
                    } else {
                        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    }
                    
                    // Use relative logical path as key
                    let urlPath = url.standardizedFileURL.path
                    if urlPath.hasPrefix(destSrcStd) {
                        var rel = String(urlPath.dropFirst(destSrcStd.count))
                        if rel.hasPrefix("/") { rel.removeFirst() }
                        liveFilePaths.insert("\(source.name)/\(rel)")
                    }
                }
            }
        }
        
        // Also count files recorded in history (to catch deleted ones)
        do {
            let historyFiles = try database.allTrackedFiles(query: nil, filter: .all)
            let historyPaths = Set(historyFiles.map { $0.logicalPath })
            
            // Active = on destination disk
            let active = liveFilePaths.count
            
            // Deleted = in history but NOT currently on destination disk
            let deleted = historyPaths.filter { path in
                !liveFilePaths.contains(path)
            }.count
            
            // Total = all unique file paths across both live destination + history
            let allPaths = liveFilePaths.union(historyPaths)
            
            self.totalCount = allPaths.count
            self.activeCount = active
            self.deletedCount = deleted
        } catch {
            // Fallback to live count only
            self.totalCount = liveFilePaths.count
            self.activeCount = liveFilePaths.count
            self.deletedCount = 0
            print("HistoryWindowViewModel: Error loading history counts: \(error)")
        }
    }

    
    public func applySort() {
        trackedFiles.sort { a, b in
            switch sortOption {
            case .dateModified, .dateAdded, .dateCreated, .dateLastOpened:
                let cmp = a.lastTimestamp.compare(b.lastTimestamp)
                if cmp != .orderedSame {
                    return sortAscending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                }
                return a.logicalPath.localizedStandardCompare(b.logicalPath) == .orderedAscending
            case .name, .tags, .sharedBy, .lastModifiedBy:
                let res = a.originalFilename.localizedStandardCompare(b.originalFilename)
                if res != .orderedSame {
                    return sortAscending ? (res == .orderedAscending) : (res == .orderedDescending)
                }
                return a.logicalPath.localizedStandardCompare(b.logicalPath) == .orderedAscending
            case .kind:
                let extA = (a.originalFilename as NSString).pathExtension.lowercased()
                let extB = (b.originalFilename as NSString).pathExtension.lowercased()
                if extA != extB {
                    return sortAscending ? (extA < extB) : (extA > extB)
                }
                let res = a.originalFilename.localizedStandardCompare(b.originalFilename)
                if res != .orderedSame {
                    return res == .orderedAscending
                }
                return a.logicalPath.localizedStandardCompare(b.logicalPath) == .orderedAscending
            case .size:
                if a.fileSize != b.fileSize {
                    return sortAscending ? (a.fileSize < b.fileSize) : (a.fileSize > b.fileSize)
                }
                return a.logicalPath.localizedStandardCompare(b.logicalPath) == .orderedAscending
            }
        }
    }
    
    public func refreshFileList(syncEngine: SyncEngine) {
        syncEngine.database.reloadFromStorageIfNeeded()
        let currentFilter = libraryFilter
        let currentSourceId = selectedSourceId
        let searchQ = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let sources = syncEngine.config.sources
            let db = syncEngine.database
            let fm = FileManager.default

            // 1. History files for metadata enrichment & deleted file counting
            let historyFiles = (try? db.allTrackedFiles(query: nil, filter: .all)) ?? []
            var historyMap: [String: TrackedFileInfo] = [:]
            for h in historyFiles { historyMap[h.logicalPath] = h }

            // 2. Enumerate destination disk (e.g. SanDisk) across all enabled sources
            var allLivePathsSet: Set<String> = []
            var allDirectoriesSet: Set<String> = []
            var liveFilesForView: [TrackedFileInfo] = []

            let destBase = syncEngine.config.syncDestination
            let isDestConnected = syncEngine.diskMonitor.isConnected

            if let dest = destBase, isDestConnected {
                for source in sources where source.isEnabled {
                    // Record source category folder so it appears in the grid/tree
                    allDirectoriesSet.insert(source.name)
                    
                    let destSourceURL = dest.appendingPathComponent(source.name)
                    guard fm.fileExists(atPath: destSourceURL.path) else { continue }
                    let destSrcStd = destSourceURL.standardizedFileURL.path
                    
                    let enumerator = fm.enumerator(
                        at: destSourceURL,
                        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    )
                    
                    while let url = enumerator?.nextObject() as? URL {
                        let name = url.lastPathComponent
                        guard !name.hasPrefix("."),
                              !SyncEngine.ignoredFolderNames.contains(name) else {
                            var isDir: ObjCBool = false
                            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                                enumerator?.skipDescendants()
                            }
                            continue
                        }
                        
                        let urlStd = url.standardizedFileURL.path
                        guard urlStd.hasPrefix(destSrcStd) else { continue }
                        var rel = String(urlStd.dropFirst(destSrcStd.count))
                        if rel.hasPrefix("/") { rel.removeFirst() }
                        guard !rel.isEmpty else { continue }
                        
                        let logicalPath = "\(source.name)/\(rel)"
                        
                        let isAppBundle = url.pathExtension.lowercased() == "app" ||
                                          (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
                        
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                            if isAppBundle {
                                enumerator?.skipDescendants()
                            } else {
                                allDirectoriesSet.insert(logicalPath)
                                continue
                            }
                        } else {
                            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                        }
                        
                        allLivePathsSet.insert(logicalPath)
                        
                        // Filter for current view
                        if let sid = currentSourceId {
                            guard source.id == sid else { continue }
                        }
                        
                        // In History view mode, only show historical/deleted files, skip active live files
                        guard currentFilter != .history else { continue }
                        
                        if !searchQ.isEmpty {
                            guard name.localizedCaseInsensitiveContains(searchQ) ||
                                  logicalPath.localizedCaseInsensitiveContains(searchQ) else { continue }
                        }
                        
                        let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey, .contentModificationDateKey])
                        var fileSize = Int64(attrs?.totalFileSize ?? attrs?.fileSize ?? 0)
                        let modDate = attrs?.contentModificationDate ?? Date()
                        
                        if isAppBundle || (fileSize == 0 && isDir.boolValue) {
                            fileSize = Self.calculateItemSize(at: url)
                        }
                        
                        if let hist = historyMap[logicalPath] {
                            let chosenSize = (fileSize > 0) ? fileSize : hist.fileSize
                            liveFilesForView.append(TrackedFileInfo(
                                logicalPath: logicalPath,
                                originalFilename: name,
                                lastChangeType: hist.lastChangeType,
                                lastTimestamp: modDate,
                                fileSize: chosenSize,
                                versionCount: hist.versionCount,
                                isDeleted: false
                            ))
                        } else {
                            liveFilesForView.append(TrackedFileInfo(
                                logicalPath: logicalPath,
                                originalFilename: name,
                                lastChangeType: .created,
                                lastTimestamp: modDate,
                                fileSize: fileSize,
                                versionCount: 0,
                                isDeleted: false
                            ))
                        }
                    }
                }
            } else {
                // Destination is disconnected or not set: populate from database history only
                for hist in historyFiles where !hist.isDeleted {
                    allLivePathsSet.insert(hist.logicalPath)
                    
                    let parts = hist.logicalPath.split(separator: "/")
                    if parts.count > 1 {
                        var dirAccum = ""
                        for part in parts.dropLast() {
                            let partStr = String(part)
                            if partStr.lowercased().hasSuffix(".app") {
                                break
                            }
                            dirAccum = dirAccum.isEmpty ? partStr : "\(dirAccum)/\(partStr)"
                            allDirectoriesSet.insert(dirAccum)
                        }
                    }
                    
                    if let sid = currentSourceId,
                       let src = sources.first(where: { $0.id == sid }) {
                        guard hist.logicalPath.hasPrefix(src.name + "/") else { continue }
                    }
                    
                    guard currentFilter != .history else { continue }
                    if !searchQ.isEmpty {
                        guard hist.originalFilename.localizedCaseInsensitiveContains(searchQ) ||
                              hist.logicalPath.localizedCaseInsensitiveContains(searchQ) else { continue }
                    }
                    liveFilesForView.append(hist)
                }
            }

            // 3. For History or All files view: show deleted/historical entries
            if currentFilter == .history || currentFilter == .all {
                for hist in historyFiles {
                    let isDeleted = hist.isDeleted || !allLivePathsSet.contains(hist.logicalPath)
                    guard isDeleted else { continue }
                    
                    // Add directory parts to allDirectoriesSet so deleted folders can be navigated into
                    let parts = hist.logicalPath.split(separator: "/")
                    if parts.count > 1 {
                        var dirAccum = ""
                        for part in parts.dropLast() {
                            let partStr = String(part)
                            if partStr.lowercased().hasSuffix(".app") { break }
                            dirAccum = dirAccum.isEmpty ? partStr : "\(dirAccum)/\(partStr)"
                            allDirectoriesSet.insert(dirAccum)
                        }
                    }
                    
                    if let sid = currentSourceId,
                       let src = sources.first(where: { $0.id == sid }) {
                        guard hist.logicalPath.hasPrefix(src.name + "/") else { continue }
                    }
                    if !searchQ.isEmpty {
                        guard hist.originalFilename.localizedCaseInsensitiveContains(searchQ) ||
                              hist.logicalPath.localizedCaseInsensitiveContains(searchQ) else { continue }
                    }
                    
                    var deletedHist = hist
                    if !deletedHist.isDeleted {
                        deletedHist = TrackedFileInfo(
                            logicalPath: hist.logicalPath,
                            originalFilename: hist.originalFilename,
                            lastChangeType: .deleted,
                            lastTimestamp: hist.lastTimestamp,
                            fileSize: hist.fileSize,
                            versionCount: hist.versionCount,
                            isDeleted: true
                        )
                    }
                    liveFilesForView.append(deletedHist)
                }
            }

            // 4. Global counts (permanent across ALL sources — never dropped when selecting a source)
            let historyPaths = Set(historyFiles.map { $0.logicalPath })
            let globalActiveCount = allLivePathsSet.count
            let globalDeletedCount = historyPaths.filter { !allLivePathsSet.contains($0) }.count
            let globalTotalCount = allLivePathsSet.union(historyPaths).count

            let finalFiles = liveFilesForView
            let finalDirectories = allDirectoriesSet

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.totalCount = globalTotalCount
                self.activeCount = globalActiveCount
                self.deletedCount = globalDeletedCount
                self.trackedFiles = finalFiles
                self.knownDirectoryPaths = finalDirectories
                self.applySort()
                self.recomputeDisplayedItems(syncEngine: syncEngine)
                
                if let selectedFolder = self.selectedFolder {
                    self.selectedFilePath = selectedFolder.path
                    self.selectedVersion = nil
                    self.fileVersions = []
                } else if let current = self.selectedFilePath,
                          finalFiles.contains(where: { $0.logicalPath == current }) {
                    // keep selection
                } else {
                    self.selectedFilePath = nil
                    self.fileVersions = []
                    self.selectedVersion = nil
                }
            }
        }
    }
    
    private var lastRevisionRefresh = Date.distantPast
    public func refreshFileListThrottled(syncEngine: SyncEngine) {
        let now = Date()
        guard now.timeIntervalSince(lastRevisionRefresh) >= 4.0 else { return }
        lastRevisionRefresh = now
        refreshFileList(syncEngine: syncEngine)
    }
    
    public func loadFileVersions(for path: String, database: HistoryDatabase, syncEngine: SyncEngine? = nil) {
        selectedFilePath = path
        do {
            var vers = try database.history(for: path)
            if let engine = syncEngine, let targetURL = engine.resolveURL(for: path) {
                let realSize = Self.calculateItemSize(at: targetURL)
                if realSize > 0 {
                    for i in 0..<vers.count {
                        if vers[i].fileSize == 0 || vers[i].originalFilename.lowercased().hasSuffix(".app") {
                            vers[i].fileSize = realSize
                        }
                    }
                }
            }
            // Check if this item is marked deleted or missing from the live source folder
            let isTrackedDeleted = trackedFiles.first(where: { $0.logicalPath == path })?.isDeleted == true
            let localSourceExists: Bool = {
                if let engine = syncEngine, let targetURL = engine.resolveURL(for: path) {
                    return FileManager.default.fileExists(atPath: targetURL.path)
                }
                return true
            }()
            let isItemDeleted = isTrackedDeleted || !localSourceExists
            
            if isItemDeleted {
                if !vers.contains(where: { $0.changeType == .deleted }) {
                    // File is deleted on Mac, but database only has prior non-deleted snapshot versions.
                    // Insert a synthesized .deleted event at the top of the timeline so deleted history is crystal clear!
                    let latestPrior = vers.first
                    let delDate = trackedFiles.first(where: { $0.logicalPath == path })?.lastTimestamp ?? Date()
                    let delVerNum = (vers.map(\.versionNumber).max() ?? 0) + 1
                    let deleteEntry = FileHistoryEntry(
                        id: UUID(),
                        sourceId: latestPrior?.sourceId ?? UUID(),
                        logicalPath: path,
                        originalFilename: latestPrior?.originalFilename ?? (path as NSString).lastPathComponent,
                        timestamp: delDate,
                        changeType: .deleted,
                        fileSize: latestPrior?.fileSize ?? 0,
                        sha256: latestPrior?.sha256 ?? "",
                        historyRelativePath: latestPrior?.historyRelativePath ?? "",
                        isCurrentVersion: true,
                        versionNumber: delVerNum
                    )
                    for i in 0..<vers.count {
                        vers[i].isCurrentVersion = false
                    }
                    vers.insert(deleteEntry, at: 0)
                } else {
                    // Database already has a .deleted version: ensure it links to the snapshot for preview & restore
                    if let delIdx = vers.firstIndex(where: { $0.changeType == .deleted }) {
                        vers[delIdx].isCurrentVersion = true
                        for i in 0..<vers.count where i != delIdx {
                            vers[i].isCurrentVersion = false
                        }
                        if vers[delIdx].historyRelativePath.isEmpty {
                            if let nonDel = vers.first(where: { $0.changeType != .deleted && !$0.historyRelativePath.isEmpty }) {
                                vers[delIdx].historyRelativePath = nonDel.historyRelativePath
                                if vers[delIdx].fileSize == 0 {
                                    vers[delIdx].fileSize = nonDel.fileSize
                                }
                            }
                        }
                    }
                }
            }
            
            self.fileVersions = vers
            self.selectedVersion = vers.first(where: { $0.isCurrentVersion }) ?? vers.first
        } catch {
            self.fileVersions = []
            self.selectedVersion = nil
        }
        
        // If file has not been archived into database yet, create a live virtual entry
        // so the inspector still shows full file details, preview, and timeline!
        if self.selectedVersion == nil, let live = trackedFiles.first(where: { $0.logicalPath == path }) {
            var liveSize = live.fileSize
            if (liveSize == 0 || live.originalFilename.lowercased().hasSuffix(".app")),
               let engine = syncEngine, let targetURL = engine.resolveURL(for: path) {
                let realSize = Self.calculateItemSize(at: targetURL)
                if realSize > 0 {
                    liveSize = realSize
                }
            }
            let liveEntry = FileHistoryEntry(
                id: UUID(),
                sourceId: UUID(),
                logicalPath: live.logicalPath,
                originalFilename: live.originalFilename,
                timestamp: live.lastTimestamp,
                changeType: live.isDeleted ? .deleted : .created,
                fileSize: liveSize,
                sha256: "",
                historyRelativePath: "",
                isCurrentVersion: true,
                versionNumber: 1
            )
            self.fileVersions = [liveEntry]
            self.selectedVersion = liveEntry
        }
    }
    
    public func navigateUp(syncEngine: SyncEngine? = nil) {
        guard let current = currentFolderPath, !current.isEmpty else { return }
        let parts = current.split(separator: "/").map(String.init)
        if parts.count > 1 {
            currentFolderPath = parts.dropLast().joined(separator: "/")
        } else {
            currentFolderPath = nil
            selectedSourceId = nil
        }
        selectedFilePath = nil
        selectedFolder = nil
        selectedVersion = nil
        fileVersions = []
        if let engine = syncEngine {
            refreshFileList(syncEngine: engine)
        }
    }
    
    public func isFolderDeleted(folderFullPath: String, syncEngine: SyncEngine) -> Bool {
        let fm = FileManager.default
        
        // 1. Check live sources on Mac
        var existsInSource = false
        var checkedAnySource = false
        for source in syncEngine.config.sources where source.isEnabled {
            let prefix = source.name + "/"
            if folderFullPath.hasPrefix(prefix) {
                checkedAnySource = true
                if fm.fileExists(atPath: source.url.path) {
                    let sub = String(folderFullPath.dropFirst(prefix.count))
                    let u = source.url.appendingPathComponent(sub)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                        existsInSource = true
                        break
                    }
                }
            } else if folderFullPath == source.name {
                checkedAnySource = true
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: source.url.path, isDirectory: &isDir), isDir.boolValue {
                    existsInSource = true
                    break
                }
            }
        }
        
        // 2. Check mirror destination
        var existsInDestination = false
        if let dest = syncEngine.config.syncDestination {
            let u = dest.appendingPathComponent(folderFullPath)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                existsInDestination = true
            }
        }
        
        // If checked against an accessible source and does not exist in that source, it's deleted locally!
        if checkedAnySource && !existsInSource {
            return true
        }
        
        // If it exists in neither live sources nor mirror destination, it's deleted
        if !existsInSource && !existsInDestination {
            return true
        }
        
        return false
    }

    public func currentFolderDisplayItem(syncEngine: SyncEngine) -> FolderDisplayItem? {
        if let folder = selectedFolder {
            return folder
        }
        
        let path = currentFolderPath ?? {
            if let sid = selectedSourceId,
               let src = syncEngine.config.sources.first(where: { $0.id == sid }) {
                return src.name
            }
            return nil
        }()
        
        guard let currentPath = path, !currentPath.isEmpty else {
            return FolderDisplayItem(
                name: libraryFilter.rawValue,
                path: "",
                itemCount: syncEngine.config.sources.count,
                lastTimestamp: trackedFiles.first?.lastTimestamp ?? Date(),
                isDeleted: false,
                versionCount: 1
            )
        }
        
        let folderName = currentPath.split(separator: "/").last.map(String.init) ?? currentPath
        
        // Count immediate children: immediate subfolders + direct files
        var subfolders = Set<String>()
        var directFiles = 0
        var latestDate = Date.distantPast
        
        for dir in knownDirectoryPaths {
            if dir.hasPrefix(currentPath + "/") {
                let sub = String(dir.dropFirst(currentPath.count + 1))
                if let first = sub.split(separator: "/").first {
                    subfolders.insert(String(first))
                }
            }
        }
        
        for file in trackedFiles {
            if file.logicalPath.hasPrefix(currentPath + "/") {
                let sub = String(file.logicalPath.dropFirst(currentPath.count + 1))
                let parts = sub.split(separator: "/")
                if parts.count == 1 {
                    directFiles += 1
                    if file.lastTimestamp > latestDate { latestDate = file.lastTimestamp }
                } else if parts.count > 1 {
                    subfolders.insert(String(parts[0]))
                    if file.lastTimestamp > latestDate { latestDate = file.lastTimestamp }
                }
            }
        }
        
        if latestDate == Date.distantPast { latestDate = Date() }
        let count = subfolders.count + directFiles
        
        let isDeleted = isFolderDeleted(folderFullPath: currentPath, syncEngine: syncEngine)
        let verCount = max(1, syncEngine.database.versionCount(forFolder: currentPath))
        
        return FolderDisplayItem(
            name: folderName,
            path: currentPath,
            itemCount: count,
            lastTimestamp: latestDate,
            isDeleted: isDeleted,
            versionCount: verCount
        )
    }
    
    public func recomputeDisplayedItems(syncEngine: SyncEngine) {
        // If searching, show all matching files directly
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            self.displayedItems = trackedFiles.map { FileManagerGridItem.file($0) }
            return
        }
        
        var basePrefix = currentFolderPath ?? ""
        if basePrefix.isEmpty {
            if let sid = selectedSourceId,
               let src = syncEngine.config.sources.first(where: { $0.id == sid }) {
                basePrefix = src.name
            }
        }
        
        let currentFilter = libraryFilter
        
        // Step 1: Collect immediate folder names and immediate files directly in basePrefix
        var immediateFolderNames = Set<String>()
        var immediateFiles: [TrackedFileInfo] = []
        
        if currentFilter == .history {
            // In History mode: only gather immediate folder names that contain deleted files
            for file in trackedFiles {
                let rel: Substring
                if basePrefix.isEmpty {
                    rel = file.logicalPath[...]
                } else if file.logicalPath.hasPrefix(basePrefix + "/") {
                    rel = file.logicalPath.dropFirst(basePrefix.count + 1)
                } else {
                    continue
                }
                let parts = rel.split(separator: "/")
                if parts.count > 1 {
                    let firstPart = String(parts[0])
                    if firstPart != basePrefix && !firstPart.isEmpty && !firstPart.lowercased().hasSuffix(".app") {
                        immediateFolderNames.insert(firstPart)
                    }
                }
            }
        } else {
            // Discovered directories from disk
            for dirPath in knownDirectoryPaths {
                let rel: String
                if basePrefix.isEmpty {
                    rel = dirPath
                } else if dirPath.hasPrefix(basePrefix + "/") {
                    rel = String(dirPath.dropFirst(basePrefix.count + 1))
                } else {
                    continue
                }
                let parts = rel.split(separator: "/")
                if parts.count >= 1 {
                    let firstPart = String(parts[0])
                    if firstPart.lowercased().hasSuffix(".app") || firstPart == basePrefix || firstPart.isEmpty {
                        continue
                    }
                    immediateFolderNames.insert(firstPart)
                }
            }
        }
        
        // Tracked files under basePrefix
        var appBundlesAdded = Set<String>()
        
        for file in trackedFiles {
            let rel: Substring
            if basePrefix.isEmpty {
                rel = file.logicalPath[...]
            } else if file.logicalPath.hasPrefix(basePrefix + "/") {
                rel = file.logicalPath.dropFirst(basePrefix.count + 1)
            } else {
                // Never add basePrefix as an item inside itself!
                continue
            }
            
            let parts = rel.split(separator: "/")
            if parts.count > 1 {
                let firstPart = String(parts[0])
                if firstPart.lowercased().hasSuffix(".app") {
                    // It's an application bundle! Collapse all files inside it into a single application file item
                    if !appBundlesAdded.contains(firstPart) {
                        appBundlesAdded.insert(firstPart)
                        let appLogicalPath = basePrefix.isEmpty ? firstPart : "\(basePrefix)/\(firstPart)"
                        var appSize: Int64 = 0
                        if let appURL = syncEngine.resolveURL(for: appLogicalPath) {
                            appSize = HistoryWindowViewModel.calculateItemSize(at: appURL)
                        }
                        if appSize == 0 {
                            let subSum = trackedFiles.filter { $0.logicalPath.hasPrefix(appLogicalPath + "/") }.reduce(0) { $0 + $1.fileSize }
                            appSize = subSum > 0 ? subSum : file.fileSize
                        }
                        let appItem = TrackedFileInfo(
                            logicalPath: appLogicalPath,
                            originalFilename: firstPart,
                            lastChangeType: file.lastChangeType,
                            lastTimestamp: file.lastTimestamp,
                            fileSize: appSize,
                            versionCount: file.versionCount,
                            isDeleted: file.isDeleted
                        )
                        immediateFiles.append(appItem)
                    }
                    continue
                }
                if firstPart != basePrefix && !firstPart.isEmpty {
                    immediateFolderNames.insert(firstPart)
                }
            } else if parts.count == 1 {
                let firstPart = String(parts[0])
                if firstPart.lowercased().hasSuffix(".app") {
                    if appBundlesAdded.contains(firstPart) {
                        continue
                    }
                    appBundlesAdded.insert(firstPart)
                    var appSize = file.fileSize
                    if appSize == 0 || appSize < 1024 {
                        if let appURL = syncEngine.resolveURL(for: file.logicalPath) {
                            let diskSize = HistoryWindowViewModel.calculateItemSize(at: appURL)
                            if diskSize > 0 { appSize = diskSize }
                        }
                        if appSize == 0 {
                            let subSum = trackedFiles.filter { $0.logicalPath.hasPrefix(file.logicalPath + "/") }.reduce(0) { $0 + $1.fileSize }
                            if subSum > 0 { appSize = subSum }
                        }
                    }
                    let appItem = TrackedFileInfo(
                        logicalPath: file.logicalPath,
                        originalFilename: file.originalFilename,
                        lastChangeType: file.lastChangeType,
                        lastTimestamp: file.lastTimestamp,
                        fileSize: appSize,
                        versionCount: file.versionCount,
                        isDeleted: file.isDeleted
                    )
                    immediateFiles.append(appItem)
                    continue
                }
                immediateFiles.append(file)
            }
        }
        
        // Step 2: For each immediate folder, calculate its direct children count and latest timestamp
        var folderInfo: [String: (itemCount: Int, lastTimestamp: Date, isDeleted: Bool, versionCount: Int)] = [:]
        
        for folderName in immediateFolderNames {
            let folderFullPath = basePrefix.isEmpty ? folderName : "\(basePrefix)/\(folderName)"
            var subfolderNames = Set<String>()
            var directFileCount = 0
            var latestDate = Date.distantPast
            
            if currentFilter == .history {
                // In history mode, count children based strictly on tracked files that are deleted
                for file in trackedFiles {
                    if file.logicalPath.hasPrefix(folderFullPath + "/") {
                        let subRel = String(file.logicalPath.dropFirst(folderFullPath.count + 1))
                        let subParts = subRel.split(separator: "/")
                        if subParts.count == 1 {
                            directFileCount += 1
                            if file.lastTimestamp > latestDate { latestDate = file.lastTimestamp }
                        } else if subParts.count > 1 {
                            subfolderNames.insert(String(subParts[0]))
                            if file.lastTimestamp > latestDate { latestDate = file.lastTimestamp }
                        }
                    }
                }
            } else {
                for dirPath in knownDirectoryPaths {
                    if dirPath.hasPrefix(folderFullPath + "/") {
                        let subRel = String(dirPath.dropFirst(folderFullPath.count + 1))
                        let subParts = subRel.split(separator: "/")
                        if let firstSub = subParts.first {
                            let subStr = String(firstSub)
                            if !subStr.lowercased().hasSuffix(".app") {
                                subfolderNames.insert(subStr)
                            }
                        }
                    }
                }
                
                var countedAppsInFolder = Set<String>()
                for file in trackedFiles {
                    if file.logicalPath.hasPrefix(folderFullPath + "/") {
                        let subRel = String(file.logicalPath.dropFirst(folderFullPath.count + 1))
                        let subParts = subRel.split(separator: "/")
                        if let firstSub = subParts.first, String(firstSub).lowercased().hasSuffix(".app") {
                            let appName = String(firstSub)
                            if !countedAppsInFolder.contains(appName) {
                                countedAppsInFolder.insert(appName)
                                directFileCount += 1
                                if file.lastTimestamp > latestDate { latestDate = file.lastTimestamp }
                            }
                            continue
                        }
                        if subParts.count == 1 {
                            directFileCount += 1
                            if file.lastTimestamp > latestDate { latestDate = file.lastTimestamp }
                        } else if subParts.count > 1 {
                            subfolderNames.insert(String(subParts[0]))
                            if file.lastTimestamp > latestDate { latestDate = file.lastTimestamp }
                        }
                    }
                }
            }
            
            let totalChildren = subfolderNames.count + directFileCount
            if latestDate == Date.distantPast { latestDate = Date() }
            
            let isDeleted = isFolderDeleted(folderFullPath: folderFullPath, syncEngine: syncEngine)
            let verCount = max(1, syncEngine.database.versionCount(forFolder: folderFullPath))
            
            folderInfo[folderName] = (
                itemCount: totalChildren,
                lastTimestamp: latestDate,
                isDeleted: isDeleted,
                versionCount: verCount
            )
        }
        
        // Filter folders according to active library filter
        let filteredFolderNames = immediateFolderNames.filter { folderName in
            if currentFilter == .active {
                return !(folderInfo[folderName]?.isDeleted ?? false)
            }
            if currentFilter == .history {
                let count = folderInfo[folderName]?.itemCount ?? 0
                let isDeleted = folderInfo[folderName]?.isDeleted ?? false
                return count > 0 || isDeleted
            }
            return true
        }
        
        // Step 3: Sort folders according to sortOption
        let sortedFolderNames = filteredFolderNames.sorted { f1, f2 in
            switch sortOption {
            case .dateModified, .dateAdded, .dateCreated, .dateLastOpened:
                let t1 = folderInfo[f1]?.lastTimestamp ?? Date.distantPast
                let t2 = folderInfo[f2]?.lastTimestamp ?? Date.distantPast
                if t1 != t2 {
                    return sortAscending ? (t1 < t2) : (t1 > t2)
                }
                return f1.localizedStandardCompare(f2) == .orderedAscending
            default:
                let res = f1.localizedStandardCompare(f2)
                if res != .orderedSame {
                    return sortAscending ? (res == .orderedAscending) : (res == .orderedDescending)
                }
                return f1.localizedStandardCompare(f2) == .orderedAscending
            }
        }
        
        var result: [FileManagerGridItem] = []
        for name in sortedFolderNames {
            let folderFullPath = basePrefix.isEmpty ? name : "\(basePrefix)/\(name)"
            let info = folderInfo[name] ?? (itemCount: 0, lastTimestamp: Date(), isDeleted: false, versionCount: 1)
            let item = FolderDisplayItem(
                name: name,
                path: folderFullPath,
                itemCount: info.itemCount,
                lastTimestamp: info.lastTimestamp,
                isDeleted: info.isDeleted,
                versionCount: info.versionCount
            )
            result.append(.folder(item))
        }
        
        // Sort immediate files
        let sortedFiles = immediateFiles.sorted { a, b in
            switch sortOption {
            case .name:
                let res = a.filename.localizedStandardCompare(b.filename)
                return sortAscending ? (res == .orderedAscending) : (res == .orderedDescending)
            case .dateModified, .dateAdded, .dateCreated, .dateLastOpened:
                let res = a.lastTimestamp.compare(b.lastTimestamp)
                if res != .orderedSame {
                    return sortAscending ? (res == .orderedAscending) : (res == .orderedDescending)
                }
                return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
            case .size:
                if a.fileSize != b.fileSize {
                    return sortAscending ? (a.fileSize < b.fileSize) : (a.fileSize > b.fileSize)
                }
                return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
            default:
                return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
            }
        }
        
        for file in sortedFiles {
            result.append(.file(file))
        }
        
        self.displayedItems = result
    }
    
    public func displayedItems(syncEngine: SyncEngine) -> [FileManagerGridItem] {
        if displayedItems.isEmpty && !trackedFiles.isEmpty {
            recomputeDisplayedItems(syncEngine: syncEngine)
        }
        return displayedItems
    }
    
    public func openFile(_ file: TrackedFileInfo, syncEngine: SyncEngine) {
        // 1. Try destination mirror file on external disk first (SanDisk)
        if let destBase = syncEngine.config.syncDestination {
            let destFileURL = destBase.appendingPathComponent(file.logicalPath)
            if FileManager.default.fileExists(atPath: destFileURL.path) {
                NSWorkspace.shared.open(destFileURL)
                return
            }
        }
        
        // 2. Try live local source fallback
        for source in syncEngine.config.sources {
            if file.logicalPath.hasPrefix(source.name + "/") {
                let sub = String(file.logicalPath.dropFirst(source.name.count + 1))
                let u = source.url.appendingPathComponent(sub)
                if FileManager.default.fileExists(atPath: u.path) {
                    NSWorkspace.shared.open(u)
                    return
                }
            } else if file.logicalPath == source.name {
                if FileManager.default.fileExists(atPath: source.url.path) {
                    NSWorkspace.shared.open(source.url)
                    return
                }
            }
        }
        
        // Fallback: extract latest version to temp and open
        if let latest = fileVersions.first {
            do {
                let tempURL = try syncEngine.storageManager.extractHistoricalFile(entry: latest)
                NSWorkspace.shared.open(tempURL)
            } catch {
                print("Failed to open file: \(error)")
            }
        }
    }
}

public struct HistoryWindowView: View {
    @ObservedObject public var syncEngine: SyncEngine
    @StateObject private var vm = HistoryWindowViewModel()
    
    public init(syncEngine: SyncEngine, initialMode: HistoryViewMode = .files) {
        self.syncEngine = syncEngine
    }
    
    public var body: some View {
        Group {
            if syncEngine.activeViewMode == .storage {
                // 2-Column SplitView: Sidebar on left + Full Storage dashboard on right
                NavigationSplitView(columnVisibility: $vm.columnVisibility) {
                    HistorySidebarView(
                        syncEngine: syncEngine,
                        libraryFilter: $vm.libraryFilter,
                        selectedSourceId: $vm.selectedSourceId,
                        totalFileCount: vm.totalCount,
                        activeCount: vm.activeCount,
                        deletedCount: vm.deletedCount,
                        onAddSource: {
                            promptAddSource()
                        },
                        onSelectStorage: {
                            syncEngine.activeViewMode = .storage
                        },
                        onFilterChange: { newFilter, newSourceId in
                            syncEngine.activeViewMode = .files
                            vm.libraryFilter = newFilter
                            vm.selectedSourceId = newSourceId
                            if let sid = newSourceId, let src = syncEngine.config.sources.first(where: { $0.id == sid }) {
                                vm.currentFolderPath = src.name
                            } else {
                                vm.currentFolderPath = nil
                            }
                            vm.selectedFilePath = nil
                            vm.selectedFolder = nil
                            vm.selectedVersion = nil
                            vm.fileVersions = []
                            vm.refreshFileList(syncEngine: syncEngine)
                        }
                    )
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            leadingNavigationGroup
                        }
                    }
                } detail: {
                    StorageView(syncEngine: syncEngine)
                        .navigationSplitViewColumnWidth(min: 600, ideal: 970, max: .infinity)
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                trailingActionsGroup
                            }
                        }
                }
            } else {
                // 3-Column SplitView: Sidebar (1) + Center File Manager (rest) + Right Inspector (2)
                NavigationSplitView(columnVisibility: $vm.columnVisibility) {
                    HistorySidebarView(
                        syncEngine: syncEngine,
                        libraryFilter: $vm.libraryFilter,
                        selectedSourceId: $vm.selectedSourceId,
                        totalFileCount: vm.totalCount,
                        activeCount: vm.activeCount,
                        deletedCount: vm.deletedCount,
                        onAddSource: {
                            promptAddSource()
                        },
                        onSelectStorage: {
                            syncEngine.activeViewMode = .storage
                        },
                        onFilterChange: { newFilter, newSourceId in
                            syncEngine.activeViewMode = .files
                            vm.libraryFilter = newFilter
                            vm.selectedSourceId = newSourceId
                            if let sid = newSourceId, let src = syncEngine.config.sources.first(where: { $0.id == sid }) {
                                vm.currentFolderPath = src.name
                            } else {
                                vm.currentFolderPath = nil
                            }
                            vm.selectedFilePath = nil
                            vm.selectedFolder = nil
                            vm.selectedVersion = nil
                            vm.fileVersions = []
                            vm.refreshFileList(syncEngine: syncEngine)
                        }
                    )
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            leadingNavigationGroup
                        }
                    }
                } content: {
                    VStack(spacing: 0) {
                        if syncEngine.activeViewMode == .files {
                            // File Manager: Icon Grid View vs List View
                            Group {
                                if vm.layoutMode == .icons {
                                    FileGridIconView(
                                        items: vm.displayedItems,
                                        selectedFilePath: $vm.selectedFilePath,
                                        syncEngine: syncEngine,
                                        onSelectFile: { path in
                                            vm.selectedFolder = nil
                                            vm.loadFileVersions(for: path, database: syncEngine.database, syncEngine: syncEngine)
                                        },
                                        onSelectFolder: { folder in
                                            vm.selectedFolder = folder
                                            vm.selectedFilePath = folder.path
                                            vm.selectedVersion = nil
                                            vm.fileVersions = []
                                        },
                                        onOpenFolder: { folderPath in
                                            vm.currentFolderPath = folderPath
                                            vm.selectedFilePath = nil
                                            vm.selectedFolder = nil
                                            vm.selectedVersion = nil
                                            vm.fileVersions = []
                                            let rootName = folderPath.split(separator: "/").first.map(String.init) ?? folderPath
                                            if let matchingSource = syncEngine.config.sources.first(where: { $0.name == rootName }) {
                                                if vm.selectedSourceId != matchingSource.id {
                                                    vm.selectedSourceId = matchingSource.id
                                                }
                                            }
                                            vm.refreshFileList(syncEngine: syncEngine)
                                        },
                                        onOpenFile: { file in
                                            vm.openFile(file, syncEngine: syncEngine)
                                        }
                                    )
                                } else {
                                    FileListView(
                                        items: vm.displayedItems,
                                        selectedFilePath: $vm.selectedFilePath,
                                        syncEngine: syncEngine,
                                        onSelectFile: { path in
                                            vm.selectedFolder = nil
                                            vm.loadFileVersions(for: path, database: syncEngine.database, syncEngine: syncEngine)
                                        },
                                        onSelectFolder: { folder in
                                            vm.selectedFolder = folder
                                            vm.selectedFilePath = folder.path
                                            vm.selectedVersion = nil
                                            vm.fileVersions = []
                                        },
                                        onOpenFolder: { folderPath in
                                            vm.currentFolderPath = folderPath
                                            vm.selectedFilePath = nil
                                            vm.selectedFolder = nil
                                            vm.selectedVersion = nil
                                            vm.fileVersions = []
                                            let rootName = folderPath.split(separator: "/").first.map(String.init) ?? folderPath
                                            if let matchingSource = syncEngine.config.sources.first(where: { $0.name == rootName }) {
                                                if vm.selectedSourceId != matchingSource.id {
                                                    vm.selectedSourceId = matchingSource.id
                                                }
                                            }
                                            vm.refreshFileList(syncEngine: syncEngine)
                                        },
                                        onOpenFile: { file in
                                            vm.openFile(file, syncEngine: syncEngine)
                                        }
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            
                            // Dynamic Finder-Style Bottom Path Bar (No Hardcoded Paths)
                            PathBarView(
                                selectedFilePath: vm.selectedFilePath,
                                selectedVersion: vm.selectedVersion,
                                currentFolderPath: vm.currentFolderPath,
                                syncEngine: syncEngine,
                                onSelectFolder: { folderPath in
                                    vm.currentFolderPath = folderPath
                                    vm.selectedFilePath = nil
                                    vm.selectedFolder = nil
                                    vm.selectedVersion = nil
                                    vm.fileVersions = []
                                    if let path = folderPath, !path.isEmpty {
                                        let rootName = path.split(separator: "/").first.map(String.init) ?? path
                                        if let src = syncEngine.config.sources.first(where: { $0.name == rootName }) {
                                            if vm.selectedSourceId != src.id {
                                                vm.selectedSourceId = src.id
                                            }
                                        }
                                    } else {
                                        vm.selectedSourceId = nil
                                    }
                                    vm.refreshFileList(syncEngine: syncEngine)
                                }
                            )
                        } else {
                            FolderSnapshotTreeView(
                                syncEngine: syncEngine,
                                selectedVersion: $vm.selectedVersion
                            )
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 350, ideal: 630, max: .infinity)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            middleToolbarGroup
                        }
                    }
                } detail: {
                    HistoricalInspectorView(
                        syncEngine: syncEngine,
                        entry: vm.selectedVersion,
                        folder: vm.selectedFolder ?? (vm.selectedVersion == nil ? vm.currentFolderDisplayItem(syncEngine: syncEngine) : nil),
                        allVersions: vm.fileVersions,
                        onSelectVersion: { ver in
                            vm.selectedVersion = ver
                        },
                        onOpenFolder: { folderPath in
                            vm.currentFolderPath = folderPath
                            vm.selectedFilePath = nil
                            vm.selectedFolder = nil
                            vm.selectedVersion = nil
                            vm.fileVersions = []
                            let rootName = folderPath.split(separator: "/").first.map(String.init) ?? folderPath
                            if let matchingSource = syncEngine.config.sources.first(where: { $0.name == rootName }) {
                                if vm.selectedSourceId != matchingSource.id {
                                    vm.selectedSourceId = matchingSource.id
                                }
                            }
                            vm.refreshFileList(syncEngine: syncEngine)
                        }
                    )
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 520)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            trailingActionsGroup
                        }
                    }
                }
                .background(SplitViewHoldingPriorityAdjuster())
            }
        }
        .navigationTitle("")
        .sheet(isPresented: $syncEngine.showSettingsSheet) {
            SettingsView(syncEngine: syncEngine, onDismiss: {
                syncEngine.showSettingsSheet = false
            })
        }
        .onChange(of: vm.libraryFilter) { _, _ in
            vm.refreshFileList(syncEngine: syncEngine)
        }
        .onChange(of: vm.selectedSourceId) { _, _ in
            vm.refreshFileList(syncEngine: syncEngine)
        }
        .onChange(of: vm.searchText) { _, _ in
            vm.refreshFileList(syncEngine: syncEngine)
        }
        .onChange(of: vm.sortOption) { _, _ in
            vm.applySort()
            vm.recomputeDisplayedItems(syncEngine: syncEngine)
        }
        .onChange(of: vm.sortAscending) { _, _ in
            vm.applySort()
            vm.recomputeDisplayedItems(syncEngine: syncEngine)
        }
        .onReceive(syncEngine.$historyRevision) { _ in
            vm.refreshFileListThrottled(syncEngine: syncEngine)
        }
        .onAppear {
            vm.refreshFileList(syncEngine: syncEngine)
        }
    }
    
    // MARK: - Toolbar Components

    private var leadingNavigationGroup: some View {
        HStack(spacing: 10) {
            LogoIconView(size: 22)
            
            Text("Sync Disk")
                .font(.system(size: 14.5, weight: .bold))
                .padding(.trailing, 2)
            
            Picker("", selection: $syncEngine.activeViewMode) {
                Text("Files").tag(HistoryViewMode.files)
                Text("Folders").tag(HistoryViewMode.folders)
                Text("Storage").tag(HistoryViewMode.storage)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
    }

    private var middleToolbarGroup: some View {
        HStack(spacing: 8) {
            // View Switcher: Icon View vs List View
            Picker("", selection: $vm.layoutMode) {
                Image(systemName: "square.grid.2x2")
                    .tag(FileViewLayoutMode.icons)
                Image(systemName: "list.bullet")
                    .tag(FileViewLayoutMode.list)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 68)
            .help("Toggle between Icon Grid View and List View")
            
            // Sort Dropdown Menu (Default: Date Modified)
            Menu {
                Section {
                    ForEach(FileSortOption.allCases, id: \.self) { option in
                        Button(action: {
                            vm.sortOption = option
                            vm.applySort()
                        }) {
                            HStack {
                                Text(option.rawValue)
                                if vm.sortOption == option {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                
                Divider()
                
                Section {
                    Button(action: {
                        vm.sortAscending = true
                        vm.applySort()
                    }) {
                        HStack {
                            Text("Ascending")
                            if vm.sortAscending {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    
                    Button(action: {
                        vm.sortAscending = false
                        vm.applySort()
                    }) {
                        HStack {
                            Text("Descending")
                            if !vm.sortAscending {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort items (Default: Date Modified)")
            
            // Search Bar
            searchBarGroup
        }
    }

    private var searchBarGroup: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            
            TextField("Search files…", text: $vm.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            
            if !vm.searchText.isEmpty {
                Button(action: { vm.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .frame(minWidth: 150, idealWidth: 200, maxWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    private var trailingActionsGroup: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            Button(action: {
                syncEngine.showSettingsSheet = true
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    private var statusColor: Color {
        if !syncEngine.diskStatus.isConnected {
            return .orange
        } else if syncEngine.syncProgress.isSyncing {
            return .accentColor
        } else {
            return .green
        }
    }
    
    private var statusText: String {
        if !syncEngine.diskStatus.isConnected {
            return "Disconnected"
        } else if syncEngine.syncProgress.isSyncing {
            return "Syncing"
        } else {
            return "Synced"
        }
    }
    
    private func promptAddSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Source"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                var current = syncEngine.config
                if !current.sources.contains(where: { $0.url == url }) {
                    let newSrc = SyncSource(name: url.lastPathComponent, url: url)
                    current.sources.append(newSrc)
                    syncEngine.updateConfig(current)
                    vm.refreshFileList(syncEngine: syncEngine)
                }
            }
        }
    }
}
