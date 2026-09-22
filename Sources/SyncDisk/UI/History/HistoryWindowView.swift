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
    @Published public var sidebarSelection: HistorySidebarSelection = .allFiles
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
    
    /// Counts all individual files across all source folders on disk (not just synced history).
    /// - totalCount:  all unique file paths (on disk + in history)
    /// - activeCount: files that exist on disk right now
    /// - deletedCount: files recorded in history but no longer on disk
    public func reloadCounts(database: HistoryDatabase, sources: [SyncSource] = []) {
        let fm = FileManager.default
        
        // Count actual files on disk across all enabled sources
        var liveFilePaths: Set<String> = []
        for source in sources where source.isEnabled {
            guard fm.fileExists(atPath: source.url.path) else { continue }
            let enumerator = fm.enumerator(
                at: source.url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            while let url = enumerator?.nextObject() as? URL {
                let name = url.lastPathComponent
                // Skip hidden/system/build files
                guard !name.hasPrefix("."),
                      !SyncEngine.ignoredFolderNames.contains(name),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { continue }
                // Use relative logical path as key
                let srcPath = source.url.standardizedFileURL.path
                let urlPath = url.standardizedFileURL.path
                if urlPath.hasPrefix(srcPath) {
                    var rel = String(urlPath.dropFirst(srcPath.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                    liveFilePaths.insert("\(source.name)/\(rel)")
                }
            }
        }
        
        // Also count files recorded in history (to catch deleted ones)
        do {
            let historyFiles = try database.allTrackedFiles(query: nil, filter: .all)
            let historyPaths = Set(historyFiles.map { $0.logicalPath })
            
            // Active = on disk (use live count if sources available, else history active)
            let active = sources.isEmpty
                ? historyFiles.filter { !$0.isCurrentDeleted }.count
                : liveFilePaths.count
            
            // Deleted = in history but NOT currently on disk
            let deleted = historyPaths.filter { path in
                !liveFilePaths.contains(path)
            }.count
            
            // Total = all unique file paths across both live + history
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
        let sidebarSel = sidebarSelection
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

            // 2. Enumerate real files and directories across all enabled sources
            var allLivePathsSet: Set<String> = []
            var allDirectoriesSet: Set<String> = []
            var liveFilesForView: [TrackedFileInfo] = []

            let showDeletedOnly = (sidebarSel == .deletedOnly)

            for source in sources where source.isEnabled {
                guard fm.fileExists(atPath: source.url.path) else { continue }
                let srcStd = source.url.standardizedFileURL.path
                
                // Track source root folder
                allDirectoriesSet.insert(source.name)
                
                let enumerator = fm.enumerator(
                    at: source.url,
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
                    guard urlStd.hasPrefix(srcStd) else { continue }
                    var rel = String(urlStd.dropFirst(srcStd.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                    guard !rel.isEmpty else { continue }
                    
                    let logicalPath = "\(source.name)/\(rel)"
                    
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        allDirectoriesSet.insert(logicalPath)
                        continue
                    }
                    
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    
                    allLivePathsSet.insert(logicalPath)
                    
                    // Filter for current view
                    let matchesSourceFilter: Bool
                    switch sidebarSel {
                    case .source(let sid):
                        matchesSourceFilter = (source.id == sid)
                    default:
                        matchesSourceFilter = true
                    }
                    
                    guard matchesSourceFilter && !showDeletedOnly else { continue }
                    
                    if !searchQ.isEmpty {
                        guard name.localizedCaseInsensitiveContains(searchQ) ||
                              logicalPath.localizedCaseInsensitiveContains(searchQ) else { continue }
                    }
                    
                    let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let fileSize = Int64(attrs?.fileSize ?? 0)
                    let modDate = attrs?.contentModificationDate ?? Date()
                    
                    if let hist = historyMap[logicalPath] {
                        liveFilesForView.append(TrackedFileInfo(
                            logicalPath: logicalPath,
                            originalFilename: name,
                            lastChangeType: hist.lastChangeType,
                            lastTimestamp: modDate,
                            fileSize: fileSize > 0 ? fileSize : hist.fileSize,
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

            // 3. For History/deleted-only view: show history entries not present on disk
            let includeDeleted = (showDeletedOnly || sidebarSel == .allFiles)
            if includeDeleted {
                for hist in historyFiles where hist.isDeleted {
                    guard !allLivePathsSet.contains(hist.logicalPath) else { continue }
                    if case .source(let sid) = sidebarSel,
                       let src = sources.first(where: { $0.id == sid }) {
                        guard hist.logicalPath.hasPrefix(src.name + "/") else { continue }
                    }
                    if !searchQ.isEmpty {
                        guard hist.originalFilename.localizedCaseInsensitiveContains(searchQ) ||
                              hist.logicalPath.localizedCaseInsensitiveContains(searchQ) else { continue }
                    }
                    liveFilesForView.append(hist)
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
        guard now.timeIntervalSince(lastRevisionRefresh) >= 0.75 else { return }
        lastRevisionRefresh = now
        refreshFileList(syncEngine: syncEngine)
    }
    
    public func loadFileVersions(for path: String, database: HistoryDatabase) {
        selectedFilePath = path
        do {
            let vers = try database.history(for: path)
            self.fileVersions = vers
            self.selectedVersion = vers.first(where: { $0.isCurrentVersion }) ?? vers.first
        } catch {
            self.fileVersions = []
            self.selectedVersion = nil
        }
        
        // If file has not been archived into database yet, create a live virtual entry
        // so the inspector still shows full file details, preview, and timeline!
        if self.selectedVersion == nil, let live = trackedFiles.first(where: { $0.logicalPath == path }) {
            let liveEntry = FileHistoryEntry(
                id: UUID(),
                sourceId: UUID(),
                logicalPath: live.logicalPath,
                originalFilename: live.originalFilename,
                timestamp: live.lastTimestamp,
                changeType: .created,
                fileSize: live.fileSize,
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
        }
        selectedFilePath = nil
        selectedFolder = nil
        selectedVersion = nil
        fileVersions = []
        if let engine = syncEngine {
            recomputeDisplayedItems(syncEngine: engine)
        }
    }
    
    public func currentFolderDisplayItem(syncEngine: SyncEngine) -> FolderDisplayItem? {
        if let folder = selectedFolder {
            return folder
        }
        
        let path = currentFolderPath ?? {
            if case .source(let sourceId) = sidebarSelection,
               let src = syncEngine.config.sources.first(where: { $0.id == sourceId }) {
                return src.name
            }
            return nil
        }()
        
        guard let currentPath = path, !currentPath.isEmpty else {
            return FolderDisplayItem(
                name: "All Files",
                path: "",
                itemCount: syncEngine.config.sources.count,
                lastTimestamp: trackedFiles.first?.lastTimestamp ?? Date()
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
        
        return FolderDisplayItem(
            name: folderName,
            path: currentPath,
            itemCount: count,
            lastTimestamp: latestDate
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
            if case .source(let sourceId) = sidebarSelection,
               let src = syncEngine.config.sources.first(where: { $0.id == sourceId }) {
                basePrefix = src.name
            }
        }
        
        // Step 1: Collect immediate folder names and immediate files directly in basePrefix
        var immediateFolderNames = Set<String>()
        var immediateFiles: [TrackedFileInfo] = []
        
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
                immediateFolderNames.insert(String(parts[0]))
            }
        }
        
        // Tracked files under basePrefix
        for file in trackedFiles {
            let rel: Substring
            if basePrefix.isEmpty {
                rel = file.logicalPath[...]
            } else if file.logicalPath.hasPrefix(basePrefix + "/") {
                rel = file.logicalPath.dropFirst(basePrefix.count + 1)
            } else if file.logicalPath == basePrefix {
                immediateFiles.append(file)
                continue
            } else {
                continue
            }
            
            let parts = rel.split(separator: "/")
            if parts.count > 1 {
                immediateFolderNames.insert(String(parts[0]))
            } else if parts.count == 1 {
                immediateFiles.append(file)
            }
        }
        
        // Step 2: For each immediate folder, calculate its direct children count and latest timestamp
        // A child of folder F is:
        // - Any unique immediate subfolder name directly inside F
        // - Any file directly inside F
        var folderInfo: [String: (itemCount: Int, lastTimestamp: Date)] = [:]
        
        for folderName in immediateFolderNames {
            let folderFullPath = basePrefix.isEmpty ? folderName : "\(basePrefix)/\(folderName)"
            var subfolderNames = Set<String>()
            var directFileCount = 0
            var latestDate = Date.distantPast
            
            for dirPath in knownDirectoryPaths {
                if dirPath.hasPrefix(folderFullPath + "/") {
                    let subRel = String(dirPath.dropFirst(folderFullPath.count + 1))
                    let subParts = subRel.split(separator: "/")
                    if let firstSub = subParts.first {
                        subfolderNames.insert(String(firstSub))
                    }
                }
            }
            
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
            
            let totalChildren = subfolderNames.count + directFileCount
            if latestDate == Date.distantPast { latestDate = Date() }
            folderInfo[folderName] = (itemCount: totalChildren, lastTimestamp: latestDate)
        }
        
        // Step 3: Sort folders according to sortOption
        let sortedFolderNames = immediateFolderNames.sorted { f1, f2 in
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
            let info = folderInfo[name] ?? (itemCount: 0, lastTimestamp: Date())
            let item = FolderDisplayItem(
                name: name,
                path: folderFullPath,
                itemCount: info.itemCount,
                lastTimestamp: info.lastTimestamp
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
        // Try live source first
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
                        selection: $vm.sidebarSelection,
                        totalFileCount: vm.totalCount,
                        activeCount: vm.activeCount,
                        deletedCount: vm.deletedCount,
                        onAddSource: {
                            promptAddSource()
                        },
                        onSelectStorage: {
                            syncEngine.activeViewMode = .storage
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
                        selection: $vm.sidebarSelection,
                        totalFileCount: vm.totalCount,
                        activeCount: vm.activeCount,
                        deletedCount: vm.deletedCount,
                        onAddSource: {
                            promptAddSource()
                        },
                        onSelectStorage: {
                            syncEngine.activeViewMode = .storage
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
                            // Sub-header when drilled into a folder
                            if let folder = vm.currentFolderPath, !folder.isEmpty {
                                HStack(spacing: 8) {
                                    Button(action: {
                                        vm.navigateUp(syncEngine: syncEngine)
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "chevron.left")
                                                .font(.system(size: 10, weight: .semibold))
                                            Text("Back")
                                                .font(.system(size: 11))
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color(nsColor: .controlBackgroundColor))
                                    )
                                    
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color.accentColor)
                                    
                                    Text(folder.split(separator: "/").last.map(String.init) ?? folder)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.primary)
                                    
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
                                
                                Divider()
                            }
                            
                            // File Manager: Icon Grid View vs List View
                            Group {
                                if vm.layoutMode == .icons {
                                    FileGridIconView(
                                        items: vm.displayedItems,
                                        selectedFilePath: $vm.selectedFilePath,
                                        syncEngine: syncEngine,
                                        onSelectFile: { path in
                                            vm.selectedFolder = nil
                                            vm.loadFileVersions(for: path, database: syncEngine.database)
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
                                            vm.recomputeDisplayedItems(syncEngine: syncEngine)
                                        },
                                        onOpenFile: { file in
                                            vm.openFile(file, syncEngine: syncEngine)
                                        }
                                    )
                                } else {
                                    FileListView(
                                        items: vm.displayedItems,
                                        selectedFilePath: $vm.selectedFilePath,
                                        onSelectFile: { path in
                                            vm.selectedFolder = nil
                                            vm.loadFileVersions(for: path, database: syncEngine.database)
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
                                            vm.recomputeDisplayedItems(syncEngine: syncEngine)
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
                                    vm.recomputeDisplayedItems(syncEngine: syncEngine)
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
        .onChange(of: vm.sidebarSelection) { _, _ in
            vm.currentFolderPath = nil
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
